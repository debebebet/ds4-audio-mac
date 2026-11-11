import CryptoKit
import Foundation

enum DriverInstallerError: LocalizedError {
    case bundleNotFound
    case cancelled
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundleNotFound:
            return "В приложении не найден файл DS4AudioDriver.driver. Пересоберите приложение."
        case .cancelled:
            return "Установка драйвера отменена."
        case .installFailed(let details):
            return "Не удалось установить драйвер: \(details)"
        }
    }
}

/// Состояние установленного в системе драйвера.
enum DriverState {
    /// Драйвер в /Library/Audio/Plug-Ins/HAL отсутствует.
    case notInstalled
    /// Установлен, но отличается от того, что лежит внутри приложения.
    case outdated
    /// Установлен и совпадает с бандлом внутри приложения.
    case current
}

/// Устанавливает HAL-драйвер «DualShock 4» в системную папку CoreAudio.
///
/// Копирование в /Library/Audio/Plug-Ins/HAL требует прав root, поэтому
/// используется стандартный диалог пароля macOS через `osascript`.
enum DriverInstaller {
    static let destination = "/Library/Audio/Plug-Ins/HAL/DS4AudioDriver.driver"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: destination)
    }

    /// Состояние драйвера в системе: установлен ли он и совпадает ли с бандлом
    /// внутри приложения. Сравнение по контрольной сумме бинарника — надёжнее,
    /// чем сравнение дат: в бандле может быть старая сборка с тем же именем.
    static var state: DriverState {
        guard isInstalled else { return .notInstalled }
        guard let source = locateDriverBundle() else { return .outdated }

        let installedBinary = URL(fileURLWithPath: destination)
            .appendingPathComponent("Contents/MacOS/DS4AudioDriver")
        let bundledBinary = source.appendingPathComponent("Contents/MacOS/DS4AudioDriver")

        guard let installedHash = sha256(of: installedBinary),
              let bundledHash = sha256(of: bundledBinary) else { return .outdated }
        return installedHash == bundledHash ? .current : .outdated
    }

    /// Умеет ли установленный драйвер убирать устройство из системы после
    /// выхода приложения. Такой драйвер прячет устройство по heartbeat-файлу.
    /// Старые сборки этого не умеют — их стоит обновить.
    static var installedDriverSupportsAutoHide: Bool {
        let info = URL(fileURLWithPath: destination)
            .appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else {
            return false
        }
        return (plist["DS4HideSupportVersion"] as? Int ?? 0) > 0
    }

    private static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func install() throws {
        guard let source = locateDriverBundle() else {
            throw DriverInstallerError.bundleNotFound
        }

        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("ds4audio-driver-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let stagedBundle = staging.appendingPathComponent("DS4AudioDriver.driver")
        try fileManager.copyItem(at: source, to: stagedBundle)

        let script = """
        set -e
        /bin/mkdir -p '/Library/Audio/Plug-Ins/HAL'
        /bin/rm -rf '\(destination)'
        /bin/cp -R '\(stagedBundle.path)' '/Library/Audio/Plug-Ins/HAL/'
        /usr/sbin/chown -R root:wheel '\(destination)'
        /bin/chmod -R go-w '\(destination)'
        /usr/bin/xattr -dr com.apple.quarantine '\(destination)' 2>/dev/null || true
        (/bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || /usr/bin/killall -9 coreaudiod) || true
        """

        let appleScript = "do shell script \"\(escapeForAppleScript(script))\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if message.contains("User canceled") || message.contains("-128") {
                throw DriverInstallerError.cancelled
            }
            throw DriverInstallerError.installFailed(
                message.isEmpty ? "код \(process.terminationStatus)" : message)
        }
    }

    static func uninstall() throws {
        let script = """
        /bin/rm -rf '\(destination)'
        (/bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || /usr/bin/killall -9 coreaudiod) || true
        """
        let appleScript = "do shell script \"\(escapeForAppleScript(script))\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DriverInstallerError.installFailed(message)
        }
    }

    // MARK: - Поиск бандла

    static func locateDriverBundle() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let env = ProcessInfo.processInfo.environment["DS4DRIVER_BUNDLE"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("DS4AudioDriver.driver"))
        }

        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var directory = executable.deletingLastPathComponent()
        for _ in 0 ..< 8 {
            candidates.append(directory.appendingPathComponent("DS4AudioDriver.driver"))
            candidates.append(directory.appendingPathComponent("build/DS4AudioDriver.driver"))
            candidates.append(directory.appendingPathComponent("tools/ds4driver/build/DS4AudioDriver.driver"))
            candidates.append(directory.appendingPathComponent("ds4driver/build/DS4AudioDriver.driver"))
            directory = directory.deletingLastPathComponent()
        }

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("tools/ds4driver/build/DS4AudioDriver.driver"))
        candidates.append(cwd.appendingPathComponent("build/DS4AudioDriver.driver"))

        var seen = Set<String>()
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
