import Foundation
import CoreAudio

/// Описание аудиоустройства CoreAudio, достаточное для маршрутизации.
struct AudioDeviceInfo: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannels: Int
    let outputChannels: Int

    var isDualShock4Driver: Bool {
        uid == AudioRouter.driverUID
    }
}

enum AudioRouterError: LocalizedError {
    case driverMissing
    case outputSwitchFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .driverMissing:
            return "Аудиодрайвер «\(AudioRouter.deviceName)» не установлен. Нажмите «Установить драйвер»."
        case .outputSwitchFailed(let status):
            return "Не удалось переключить вывод системы на «\(AudioRouter.deviceName)» (OSStatus \(status))"
        }
    }
}

/// Управление системным аудиовыводом.
///
/// В проекте есть собственное виртуальное loopback-устройство
/// «DualShock 4» (`tools/ds4driver`). Оно принимает звук приложений и отдаёт
/// его как вход:
///
///     система → «DualShock 4» (HAL-драйвер) → ds4probe
///             → SBC 16 кГц → Bluetooth HID → динамик контроллера
///
/// BlackHole и агрегатные устройства больше не нужны.
final class AudioRouter {
    static let deviceName = "DualShock 4"
    static let driverUID = "com.ds4audio.driver.dualshock4"

    private let defaults = UserDefaults.standard
    private let previousOutputUIDKey = "ds4.router.previousOutputUID"
    private let previousSystemOutputUIDKey = "ds4.router.previousSystemOutputUID"

    // MARK: - Список устройств

    func allDevices() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { info(for: $0) }
    }

    func info(for id: AudioDeviceID) -> AudioDeviceInfo? {
        guard let name = name(of: id), let uid = uid(of: id) else { return nil }
        return AudioDeviceInfo(id: id,
                               name: name,
                               uid: uid,
                               inputChannels: channelCount(id, scope: kAudioDevicePropertyScopeInput),
                               outputChannels: channelCount(id, scope: kAudioDevicePropertyScopeOutput))
    }

    func device(withUID uid: String) -> AudioDeviceInfo? {
        allDevices().first(where: { $0.uid == uid })
    }

    /// Наше виртуальное устройство. Ищем по UID, затем по имени — на случай
    /// старой установки драйвера с другим UID.
    func driverDevice() -> AudioDeviceInfo? {
        if let device = device(withUID: Self.driverUID) {
            return device
        }
        return allDevices().first {
            $0.name == Self.deviceName && $0.inputChannels > 0 && $0.outputChannels > 0
        }
    }

    func ensureDriverDevice() throws -> AudioDeviceInfo {
        guard let device = driverDevice() else {
            throw AudioRouterError.driverMissing
        }
        return device
    }

    func currentDefaultOutput(system: Bool = false) -> AudioDeviceInfo? {
        guard let id = defaultOutputID(system: system) else { return nil }
        return info(for: id)
    }

    func isDriverDefault() -> Bool {
        guard let driver = driverDevice() else { return false }
        return defaultOutputID(system: false) == driver.id
            || defaultOutputID(system: true) == driver.id
    }

    // MARK: - Переключение вывода

    /// Запоминает текущий вывод, чтобы вернуть его при выключении режима.
    func rememberCurrentOutputs() {
        if let output = currentDefaultOutput(system: false),
           output.uid != Self.driverUID {
            defaults.set(output.uid, forKey: previousOutputUIDKey)
        }
        if let systemOutput = currentDefaultOutput(system: true),
           systemOutput.uid != Self.driverUID {
            defaults.set(systemOutput.uid, forKey: previousSystemOutputUIDKey)
        }
    }

    /// Делает «DualShock 4» выводом системы. Возвращает false, если основной
    /// вывод переключить не удалось.
    @discardableResult
    func setDriverAsDefault(_ device: AudioDeviceInfo) -> Bool {
        rememberCurrentOutputs()
        let outputOK = setDefaultOutput(device.id, system: false)
        // Системные звуки тоже уводим в DS4, но их ошибка не критична.
        _ = setDefaultOutput(device.id, system: true)
        return outputOK
    }

    /// Возвращает прежний вывод, если сейчас выбран «DualShock 4».
    @discardableResult
    func restoreSystemOutputIfNeeded() -> Bool {
        guard let driver = driverDevice() else { return false }
        var restored = false

        if defaultOutputID(system: false) == driver.id,
           let previous = savedPreviousOutput() {
            restored = setDefaultOutput(previous.id, system: false) || restored
        }
        if defaultOutputID(system: true) == driver.id,
           let previous = savedPreviousSystemOutput() {
            restored = setDefaultOutput(previous.id, system: true) || restored
        }

        // Аварийный вариант: сохранённое устройство исчезло.
        if defaultOutputID(system: false) == driver.id,
           let fallback = fallbackOutput(excluding: driver.id) {
            restored = setDefaultOutput(fallback.id, system: false) || restored
        }
        if defaultOutputID(system: true) == driver.id,
           let fallback = fallbackOutput(excluding: driver.id) {
            restored = setDefaultOutput(fallback.id, system: true) || restored
        }
        return restored
    }

    /// После аварийного завершения приложения вывод мог остаться на драйвере.
    func recoverStaleDriver() {
        guard let driver = driverDevice() else { return }
        if defaultOutputID(system: false) == driver.id
            || defaultOutputID(system: true) == driver.id {
            _ = restoreSystemOutputIfNeeded()
        }
    }

    // MARK: - CoreAudio

    private func defaultOutputID(system: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: system ? kAudioHardwarePropertyDefaultSystemOutputDevice
                              : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    @discardableResult
    private func setDefaultOutput(_ id: AudioDeviceID, system: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: system ? kAudioHardwarePropertyDefaultSystemOutputDevice
                              : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size),
                                                &device)
        return status == noErr
    }

    private func savedPreviousOutput() -> AudioDeviceInfo? {
        guard let uid = defaults.string(forKey: previousOutputUIDKey),
              let device = device(withUID: uid),
              device.uid != Self.driverUID else { return nil }
        return device
    }

    private func savedPreviousSystemOutput() -> AudioDeviceInfo? {
        guard let uid = defaults.string(forKey: previousSystemOutputUIDKey),
              let device = device(withUID: uid),
              device.uid != Self.driverUID else { return nil }
        return device
    }

    private func fallbackOutput(excluding driverID: AudioDeviceID) -> AudioDeviceInfo? {
        let outputs = allDevices().filter {
            $0.outputChannels > 0 && $0.id != driverID && $0.uid != Self.driverUID
        }
        if let builtIn = outputs.first(where: {
            let n = $0.name.lowercased()
            return n.contains("macbook") || n.contains("built-in") || n.contains("встроен")
                || n.contains("speaker") || n.contains("динамик")
        }) {
            return builtIn
        }
        return outputs.first
    }

    private func name(of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else {
            return nil
        }
        return name as String
    }

    private func uid(of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr else {
            return nil
        }
        return uid as String
    }

    private func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
