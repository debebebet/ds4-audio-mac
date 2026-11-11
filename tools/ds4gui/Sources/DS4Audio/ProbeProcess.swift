import Foundation

/// Обёртка над дочерним процессом `ds4probe`.
///
/// GUI не дублирует весь протокол: проверенный стример остаётся в `ds4probe`.
/// Приложение запускает его в режиме системного звука, читает журнал и
/// передаёт живую громкость через небольшой файл (`--volume-file`).
final class ProbeProcess {
    private let fileManager = FileManager.default
    private var process: Process?
    private var controlDirectory: URL?
    private var controlFile: URL?
    private var outputPipe: Pipe?

    /// Строки stdout/stderr. Приходят не на главном потоке.
    var onLog: ((String) -> Void)?
    /// Процесс завершился. Код возврата. Приходит не на главном потоке.
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    // MARK: - Запуск

    func start(volume: UInt8, captureDevice: String) throws {
        guard process == nil || process?.isRunning == false else { return }
        guard let binary = Self.locateProbeBinary() else {
            throw ProbeProcessError.binaryNotFound
        }

        let controlFile = try makeControlFile(volume: volume)
        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = binary.deletingLastPathComponent()
        process.arguments = [
            "--transport", "bluetooth",
            "--wait", "8",
            "--seconds", "86400",
            "--volume", String(format: "0x%02X", volume),
            "--rate", "16000",
            "--bitpool", "12",
            "--report", "0x16",
            "--frames", "10",
            "--target", "speaker",
            "--system-audio",
            "--capture-device", captureDevice,
            "--capture-gain", "16",
            "--volume-file", controlFile.path,
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) {
                    self?.onLog?(text)
                }
                return
            }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newline]
                buffer.removeSubrange(...newline)
                if let line = String(data: lineData, encoding: .utf8) {
                    let cleaned = line.trimmingCharacters(in: .newlines)
                    if !cleaned.isEmpty { self?.onLog?(cleaned) }
                }
            }
        }

        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.onExit?(code)
            }
        }

        try process.run()
        self.process = process
        self.outputPipe = pipe
    }

    // MARK: - Громкость на лету

    func setVolume(_ value: UInt8) {
        guard let controlFile else { return }
        try? String(format: "0x%02X\n", value)
            .write(to: controlFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Остановка

    func stop() {
        guard let process else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            // Даём процессу шанс завершиться; если он завис в
            // IOHIDDeviceSetReport (контроллер уснул), добиваем SIGKILL.
            let deadline = Date().addingTimeInterval(1.0)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(pid, SIGKILL)
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        self.process = nil
        self.outputPipe = nil
        cleanupControlFile()
    }

    deinit {
        stop()
    }

    // MARK: - Вспомогательное

    private func makeControlFile(volume: UInt8) throws -> URL {
        cleanupControlFile()
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("ds4audio-gui-volume-\(ProcessInfo.processInfo.processIdentifier)-\(Int(Date().timeIntervalSince1970))",
                                    isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("volume.txt")
        try String(format: "0x%02X\n", volume)
            .write(to: file, atomically: true, encoding: .utf8)
        controlDirectory = dir
        controlFile = file
        return file
    }

    private func cleanupControlFile() {
        if let controlDirectory {
            try? fileManager.removeItem(at: controlDirectory)
        }
        controlDirectory = nil
        controlFile = nil
    }

    /// Ищет `ds4probe` рядом с приложением, внутри .app или в дереве проекта.
    static func locateProbeBinary() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let env = ProcessInfo.processInfo.environment["DS4PROBE_BIN"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("ds4probe"))
        }

        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var directory = executable.deletingLastPathComponent()
        for _ in 0 ..< 8 {
            candidates.append(directory.appendingPathComponent("ds4probe"))
            candidates.append(directory.appendingPathComponent("release/ds4probe"))
            candidates.append(directory.appendingPathComponent(".build/release/ds4probe"))
            candidates.append(directory.appendingPathComponent("tools/ds4probe/.build/release/ds4probe"))
            candidates.append(directory.appendingPathComponent("ds4probe/.build/release/ds4probe"))
            directory = directory.deletingLastPathComponent()
        }

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("tools/ds4probe/.build/release/ds4probe"))
        candidates.append(cwd.appendingPathComponent(".build/release/ds4probe"))

        var seen = Set<String>()
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            if fileManager.isExecutableFile(atPath: path) {
                return candidate
            }
        }
        return nil
    }
}

enum ProbeProcessError: LocalizedError {
    case binaryNotFound

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Не найден исполняемый файл ds4probe. Соберите его: cd tools/ds4probe && swift build -c release"
        }
    }
}
