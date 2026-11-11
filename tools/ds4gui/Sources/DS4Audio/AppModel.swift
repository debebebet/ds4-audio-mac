import AppKit
import Combine
import Foundation

/// Состояние приложения и вся логика автоподхвата/маршрутизации.
@MainActor
final class AppModel: ObservableObject {
    enum Status {
        case searching
        case connected
        case streaming
        case waiting
        case usbOnly
        case error
    }

    // MARK: - Публичное состояние

    @Published private(set) var devices: [DS4DeviceInfo] = []
    @Published private(set) var bluetoothDevice: DS4DeviceInfo?
    @Published private(set) var usbDevice: DS4DeviceInfo?
    @Published private(set) var lastScan: Date?

    @Published private(set) var volume: Double
    @Published private(set) var volumeByte: UInt8

    @Published private(set) var systemAudioEnabled: Bool
    @Published private(set) var isStreaming = false
    @Published private(set) var waitingForController = false
    @Published private(set) var restartSuspended = false
    @Published private(set) var routerReady = false
    @Published private(set) var driverInstalled = false
    @Published private(set) var driverState: DriverState = .notInstalled
    @Published private(set) var isInstallingDriver = false
    @Published private(set) var captureDeviceName: String?
    @Published private(set) var currentOutputName = "—"

    @Published private(set) var logLines: [String] = []
    @Published private(set) var lastLogLine = ""
    @Published var errorMessage: String?

    /// Показывать ли мастер первоначальной настройки.
    @Published var showSetup = false

    // MARK: - Внутреннее

    private let scanner = ControllerScanner()
    private let router = AudioRouter()
    private let probe = ProbeProcess()
    private let heartbeat = DriverHeartbeat()
    private let defaults = UserDefaults.standard

    private var started = false
    private var didShutdown = false
    private var consecutiveFailures = 0
    private var lastStartAttempt = Date.distantPast
    private var signalSources: [DispatchSourceSignal] = []
    private var notificationTokens: [NSObjectProtocol] = []

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - Init

    init() {
        let savedVolume = defaults.object(forKey: "ds4.volumeByte") as? Int ?? Int(0x18)
        let byte = UInt8(clamping: max(0, min(0x4F, savedVolume)))
        volumeByte = byte
        volume = Double(byte) / 79.0
        systemAudioEnabled = defaults.bool(forKey: "ds4.systemAudioEnabled")
        // Первый запуск — показываем мастер настройки.
        showSetup = !defaults.bool(forKey: "ds4.setupCompleted")
    }

    // MARK: - Жизненный цикл

    func start() {
        guard !started else { return }
        started = true
        setupNotifications()

        // Heartbeat запускаем первым: пока он свежий, драйвер держит устройство
        // «DualShock 4» в системе, и только тогда его можно выбрать выводом.
        heartbeat.start()
        appendLog("Heartbeat драйвера запущен")

        // Если прошлый запуск завершился аварийно, вывод мог остаться на
        // драйвере «DualShock 4». Возвращаем системный звук.
        router.recoverStaleDriver()
        refreshAudioEnvironment()

        if systemAudioEnabled {
            if routerReady {
                waitingForController = bluetoothDevice == nil
            } else {
                errorMessage = AudioRouterError.driverMissing.localizedDescription
                appendLog("Драйвер «\(AudioRouter.deviceName)» не найден")
            }
        }

        scanner.onUpdate = { [weak self] devices in
            Task { @MainActor in self?.handleScan(devices) }
        }
        scanner.start(interval: 5)
        appendLog("Автопоиск DualShock 4: скан каждые 5 секунд")
    }

    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        scanner.stop()
        probe.stop()
        router.restoreSystemOutputIfNeeded()
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        for source in signalSources {
            source.cancel()
        }
        signalSources.removeAll()

        // Heartbeat гасим последним: пока он свежий, устройство «DualShock 4»
        // остаётся в системе, поэтому прежний вывод мы уже успели вернуть.
        // После этого драйвер убирает устройство из списка CoreAudio.
        heartbeat.stop()
        appendLog("Приложение закрыто, устройство убрано из системы")
    }

    // MARK: - Публичные действия

    func checkNow() {
        appendLog("Ручная проверка контроллера…")
        scanner.scanNow()
    }

    func setSystemAudioEnabled(_ enabled: Bool) {
        guard enabled != systemAudioEnabled else { return }
        systemAudioEnabled = enabled
        defaults.set(enabled, forKey: "ds4.systemAudioEnabled")
        errorMessage = nil

        if enabled {
            refreshAudioEnvironment()
            guard let driver = router.driverDevice() else {
                systemAudioEnabled = false
                defaults.set(false, forKey: "ds4.systemAudioEnabled")
                errorMessage = AudioRouterError.driverMissing.localizedDescription
                appendLog("Драйвер «\(AudioRouter.deviceName)» не установлен")
                return
            }
            routerReady = true
            captureDeviceName = driver.name

            consecutiveFailures = 0
            restartSuspended = false
            appendLog("Системный режим включён: вывод «\(AudioRouter.deviceName)»")
            if bluetoothDevice != nil {
                startStream()
            } else {
                waitingForController = true
                appendLog("Контроллер не подключён — жду подключения по Bluetooth")
            }
        } else {
            waitingForController = false
            restartSuspended = false
            stopStream(reason: "системный режим выключен")
            router.restoreSystemOutputIfNeeded()
            routerReady = router.driverDevice() != nil
            currentOutputName = router.currentDefaultOutput()?.name ?? "—"
            appendLog("Системный режим выключен, вывод системы восстановлен")
        }
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        let byte = UInt8((clamped * 79.0).rounded())
        volume = Double(byte) / 79.0
        guard byte != volumeByte else { return }
        volumeByte = byte
        defaults.set(Int(byte), forKey: "ds4.volumeByte")
        probe.setVolume(byte)
    }

    func retryStream() {
        restartSuspended = false
        consecutiveFailures = 0
        lastStartAttempt = .distantPast
        errorMessage = nil
        if systemAudioEnabled, bluetoothDevice != nil {
            startStream()
        }
    }

    /// Устанавливает HAL-драйвер «DualShock 4» (запросит пароль администратора).
    ///
    /// - Parameter enableSystemAudio: сразу включать системный режим после
    ///   установки. В мастере настройки это не нужно — там пользователь сам
    ///   решает, когда включать.
    func installDriver(enableSystemAudio: Bool = true) {
        guard !isInstallingDriver else { return }
        isInstallingDriver = true
        errorMessage = nil
        appendLog("Установка аудиодрайвера «\(AudioRouter.deviceName)»…")

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try DriverInstaller.install()
                }.value

                // coreaudiod перезапускается не мгновенно — ждём устройство.
                var appeared = false
                for _ in 0 ..< 30 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    refreshAudioEnvironment()
                    if routerReady {
                        appeared = true
                        break
                    }
                }
                guard appeared else {
                    throw AudioRouterError.driverMissing
                }

                appendLog("Драйвер установлен: «\(AudioRouter.deviceName)»")
                isInstallingDriver = false
                if !enableSystemAudio {
                    return
                }
                if !systemAudioEnabled {
                    setSystemAudioEnabled(true)
                } else if bluetoothDevice != nil {
                    startStream()
                }
            } catch {
                isInstallingDriver = false
                errorMessage = error.localizedDescription
                appendLog("Ошибка установки драйвера: \(error.localizedDescription)")
            }
        }
    }

    func clearLog() {
        logLines.removeAll()
        lastLogLine = ""
    }

    /// Мастер настройки пройден — больше не показываем его при запуске.
    func finishSetup() {
        defaults.set(true, forKey: "ds4.setupCompleted")
        showSetup = false
    }

    /// Открыть мастер настройки из главного окна.
    func openSetup() {
        showSetup = true
    }

    // MARK: - Производные значения

    var status: Status {
        if isStreaming { return .streaming }
        if errorMessage != nil { return .error }
        if systemAudioEnabled && bluetoothDevice == nil { return .waiting }
        if bluetoothDevice != nil { return .connected }
        if usbDevice != nil { return .usbOnly }
        return .searching
    }

    var statusTitle: String {
        switch status {
        case .streaming:
            return "Звук идёт в DualShock 4"
        case .connected:
            return "\(bluetoothDevice?.product ?? "DualShock 4") подключён"
        case .waiting:
            return "Жду подключения контроллера"
        case .usbOnly:
            return "Контроллер подключён по USB"
        case .error:
            return "Нужно внимание"
        case .searching:
            return "Поиск DualShock 4"
        }
    }

    var volumePercent: Int {
        Int((Double(volumeByte) / 79.0 * 100).rounded())
    }

    var volumeHex: String {
        String(format: "0x%02X", volumeByte)
    }

    var canEnableSystemAudio: Bool {
        routerReady
    }

    var controllerSubtitle: String {
        if let device = bluetoothDevice {
            return "\(device.transport) · \(device.vidPID)"
        }
        if let device = usbDevice {
            return "USB · \(device.vidPID) — звук в динамик недоступен"
        }
        return "Подключите геймпад по Bluetooth"
    }

    // MARK: - Скан

    private func handleScan(_ found: [DS4DeviceInfo]) {
        devices = found
        lastScan = Date()

        let newBluetooth = found.first(where: { $0.isBluetooth })
        let newUSB = found.first(where: { !$0.isBluetooth })
        let previousBluetooth = bluetoothDevice
        bluetoothDevice = newBluetooth
        usbDevice = newUSB

        if newBluetooth?.id != previousBluetooth?.id {
            if let newBluetooth {
                appendLog("Найден \(newBluetooth.product) (\(newBluetooth.vidPID), \(newBluetooth.transport))")
                consecutiveFailures = 0
                restartSuspended = false
                errorMessage = nil
            } else if previousBluetooth != nil {
                appendLog("DualShock 4 отключён")
            }
        }

        // Контроллер пропал во время стрима — гасим поток и возвращаем звук.
        if isStreaming, newBluetooth == nil {
            appendLog("Контроллер пропал — останавливаю поток")
            stopStream(reason: "контроллер отключён")
            router.restoreSystemOutputIfNeeded()
            waitingForController = systemAudioEnabled
        }

        if systemAudioEnabled {
            if newBluetooth != nil, !isStreaming, !restartSuspended {
                maybeStartStream()
            } else if newBluetooth == nil {
                waitingForController = true
            }
        }

        refreshAudioEnvironment()
    }

    private func maybeStartStream() {
        guard systemAudioEnabled,
              let device = bluetoothDevice,
              device.isBluetooth,
              !isStreaming else { return }
        // Не долбим запуском каждые 5 секунд, если предыдущая попытка упала.
        guard Date().timeIntervalSince(lastStartAttempt) > 6 else { return }
        lastStartAttempt = Date()
        startStream()
    }

    // MARK: - Поток

    /// Ждёт появления устройства «DualShock 4» в системе.
    ///
    /// Драйвер публикует устройство не мгновенно: сначала он должен увидеть
    /// свежий heartbeat-файл, а это происходит в пределах секунды. Без ожидания
    /// первый запуск потока сразу после старта приложения падал бы с ошибкой
    /// «драйвер не установлен» и восстанавливался только через 5 секунд.
    private func waitForDriverDevice(timeout: TimeInterval = 3.0) throws -> AudioDeviceInfo {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let device = router.driverDevice() { return device }
            guard Date() < deadline else { throw AudioRouterError.driverMissing }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func startStream() {
        guard systemAudioEnabled,
              !isStreaming,
              let device = bluetoothDevice else { return }

        errorMessage = nil
        do {
            let driver = try waitForDriverDevice()
            routerReady = true
            captureDeviceName = driver.name

            if !router.isDriverDefault() {
                guard router.setDriverAsDefault(driver) else {
                    throw AudioRouterError.outputSwitchFailed(-1)
                }
            }

            try probe.start(volume: volumeByte, captureDevice: driver.name)
            isStreaming = true
            waitingForController = false
            consecutiveFailures = 0
            currentOutputName = router.currentDefaultOutput()?.name ?? AudioRouter.deviceName
            appendLog("Поток запущен: система → \(driver.name) → \(device.product)")
        } catch {
            isStreaming = false
            consecutiveFailures += 1
            errorMessage = error.localizedDescription
            appendLog("Ошибка запуска: \(error.localizedDescription)")
            router.restoreSystemOutputIfNeeded()
            currentOutputName = router.currentDefaultOutput()?.name ?? "—"
            if consecutiveFailures >= 3 {
                restartSuspended = true
                appendLog("Три неудачных запуска подряд — автоперезапуск приостановлен")
            }
        }
    }

    private func stopStream(reason: String) {        let wasRunning = isStreaming || probe.isRunning
        isStreaming = false
        probe.stop()
        if wasRunning {
            appendLog("Поток остановлен: \(reason)")
        }
    }

    private func handleProbeExit(_ code: Int32) {
        guard isStreaming else { return }
        isStreaming = false
        appendLog("ds4probe завершился (код \(code))")
        guard systemAudioEnabled else { return }

        router.restoreSystemOutputIfNeeded()
        currentOutputName = router.currentDefaultOutput()?.name ?? "—"
        consecutiveFailures += 1
        if consecutiveFailures >= 3 {
            restartSuspended = true
            appendLog("Три неудачных запуска подряд — автоперезапуск приостановлен")
        }
        waitingForController = bluetoothDevice == nil
    }

    // MARK: - Окружение

    private func refreshAudioEnvironment() {
        let all = router.allDevices()
        if let driver = all.first(where: { $0.isDualShock4Driver })
            ?? all.first(where: {
                $0.name == AudioRouter.deviceName && $0.inputChannels > 0 && $0.outputChannels > 0
            }) {
            routerReady = true
            captureDeviceName = driver.name
        } else {
            routerReady = false
            captureDeviceName = nil
        }
        driverInstalled = routerReady || DriverInstaller.isInstalled
        driverState = DriverInstaller.state
        currentOutputName = router.currentDefaultOutput()?.name ?? "—"
    }

    // MARK: - Журнал

    private func appendLog(_ line: String) {
        let stamped = "\(Self.timeFormatter.string(from: Date()))  \(line)"
        lastLogLine = line
        logLines.append(stamped)
        if logLines.count > 400 {
            logLines.removeFirst(logLines.count - 400)
        }
    }

    // MARK: - Завершение и сигналы

    private func setupNotifications() {
        probe.onLog = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        probe.onExit = { [weak self] code in
            Task { @MainActor in self?.handleProbeExit(code) }
        }

        let terminate = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.shutdown() }
        }
        notificationTokens.append(terminate)

        // Ctrl-C / SIGTERM при запуске из терминала: вернуть системный вывод
        // и погасить дочерний процесс.
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.shutdown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
