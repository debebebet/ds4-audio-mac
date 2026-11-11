import Foundation

/// Heartbeat-файл, по которому HAL-драйвер понимает, что приложение живо.
///
/// Пока файл свежий, драйвер держит устройство «DualShock 4» опубликованным в
/// системе: без этого его нельзя выбрать выводом по умолчанию. Когда
/// приложение закрывается, файл удаляется — и через несколько сотен
/// миллисекунд устройство исчезает из списка CoreAudio.
///
/// Файл служит и страховкой от падения: если приложение упало, не удалив файл,
/// heartbeat всё равно протухнет и устройство будет убрано.
///
/// Путь должен совпадать с `kHeartbeatPath` в `tools/ds4driver/Driver.cpp`.
final class DriverHeartbeat {
    static let path = "/var/tmp/com.ds4audio.gui.heartbeat"

    /// Как часто обновляем файл. Драйвер считает heartbeat протухшим после
    /// четырёх секунд молчания, поэтому секунда — достаточный запас.
    private static let refreshInterval: TimeInterval = 1.0

    private let fileManager = FileManager.default
    private var timer: DispatchSourceTimer?
    private var handle: FileHandle?

    /// Работает ли heartbeat сейчас.
    var isRunning: Bool { timer != nil }

    // MARK: - Запуск

    func start() {
        stop()

        createFile()
        write()

        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + Self.refreshInterval,
                       repeating: Self.refreshInterval)
        timer.setEventHandler { [weak self] in self?.write() }
        timer.resume()
        self.timer = timer
    }

    /// Останавливает heartbeat и убирает файл: устройство должно исчезнуть
    /// из системы.
    func stop() {
        timer?.cancel()
        timer = nil

        try? handle?.close()
        handle = nil

        try? fileManager.removeItem(atPath: Self.path)
    }

    // MARK: - Вспомогательное

    private func createFile() {
        let url = URL(fileURLWithPath: Self.path)
        if !fileManager.fileExists(atPath: Self.path) {
            fileManager.createFile(atPath: Self.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
    }

    private func write() {
        // Файл мог исчезнуть (например, очистка /var/tmp) — тогда создаём заново.
        if !fileManager.fileExists(atPath: Self.path) {
            createFile()
        }
        guard let handle else { return }

        let stamp = String(format: "%.3f\n", Date().timeIntervalSince1970)
        handle.seekToEndOfFile()
        handle.write(Data(stamp.utf8))
    }

    deinit {
        stop()
    }
}
