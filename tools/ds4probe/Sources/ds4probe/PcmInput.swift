import Darwin
import Foundation

// MARK: - Потоковый PCM-вход
//
// Режим предназначен для связки «Dolphin → helper»: Dolphin выдаёт уже
// декодированные сэмплы динамика Wiimote (s16, моно, частота зависит от
// регистра sample_rate_divisor), helper приводит их к 16 кГц и отправляет
// в DS4.
//
// Вход — сырой поток PCM s16 little-endian либо блоки «D4P1» из Dolphin.
// Стерео сводится в моно усреднением, затем дублируется в оба канала SBC
// с половинной амплитудой: встроенный динамик DS4 моно и складывает L+R,
// поэтому полная амплитуда в каждом канале дала бы клиппинг.

/// Потоковый линейный ресемплер. Сохраняет состояние между блоками,
/// поэтому на границах блоков нет разрывов.
final class LinearResampler {
    let inputRate: Int
    let outputRate: Int
    private var buffer: [Float] = []
    private var position: Double = 0
    private let step: Double

    init(inputRate: Int, outputRate: Int) {
        precondition(inputRate > 0 && outputRate > 0)
        self.inputRate = inputRate
        self.outputRate = outputRate
        step = Double(inputRate) / Double(outputRate)
        buffer.reserveCapacity(4096)
    }

    /// Принимает моно-сэмплы во входной частоте, возвращает моно-сэмплы
    /// в выходной частоте.
    func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        buffer.append(contentsOf: input)

        var output: [Float] = []
        output.reserveCapacity(Int(Double(input.count) * Double(outputRate) / Double(inputRate)) + 2)

        // Для интерполяции нужны два соседних входных сэмпла.
        while Int(position) + 1 < buffer.count {
            let index = Int(position)
            let fraction = position - Double(index)
            let a = buffer[index]
            let b = buffer[index + 1]
            output.append(a + (b - a) * Float(fraction))
            position += step
        }

        // Оставляем один входной сэмпл как «предыдущий» и переносим
        // остаток дробной позиции на следующий блок.
        let consumed = max(0, Int(position) - 1)
        if consumed > 0 {
            buffer.removeFirst(consumed)
            position -= Double(consumed)
        }
        return output
    }
}

/// Читает PCM из stdin или файла в фоновом потоке и отдаёт кадры по
/// 128 стерео-сэмплов для SBC-энкодера.
final class PcmStreamSource {
    private enum Endpoint {
        case handle(FileHandle)
        case unixSocket(path: String)
    }

    private var inputRate: Int
    private var inputChannels: Int
    let outputRate: Int
    private let endpoint: Endpoint
    private var listenFD: Int32 = -1
    private var connectionFD: Int32 = -1
    private let ring: SampleRing
    private var resampler: LinearResampler
    /// Размер буфера в выходных стерео-сэмплах (≈500 мс).
    private let maxBufferedSamples: Int
    private let volume: Double

    private let stateLock = NSLock()
    private var ioFinished = false
    private var stopRequested = false
    private var readError: String?
    private var droppedInputSamples = 0
    private var overruns = 0
    /// Неполный кадр на границе чтения: переносим в следующий блок,
    /// иначе каждый второй блок теряет часть сэмплов.
    private var carry: [UInt8] = []
    /// Буфер двоичного протокола сокета Dolphin («D4P1»).
    private var framedCarry: [UInt8] = []
    /// Тормозить чтение при заполненном буфере (не нужно в selftest).
    private var throttleReads = true

    private(set) var underruns = 0
    private(set) var inputFrames: Int64 = 0
    private(set) var outputFrames: Int64 = 0
    private(set) var inputSeconds: Double = 0
    private(set) var peakLevel: Int = 0

    /// Ёмкость буфера: 500 мс выходного стерео. Больше не нужно: при
    /// переполнении лучше потерять старый звук, чем накапливать задержку.
    init(inputRate: Int, channels: Int, reader: FileHandle, outputRate: Int = 16_000,
         volume: Double = 1.0) {
        self.inputRate = inputRate
        self.inputChannels = max(1, min(2, channels))
        self.outputRate = outputRate
        endpoint = .handle(reader)
        self.volume = max(0.0, min(4.0, volume))
        maxBufferedSamples = outputRate  // 500 мс стерео
        ring = SampleRing(capacity: outputRate * 2)
        resampler = LinearResampler(inputRate: inputRate, outputRate: outputRate)
    }

    /// Unix domain socket: слушаем `path`, принимаем PCM от первого
    /// подключившегося клиента. После разрыва ждём следующего клиента,
    /// не завершая процесс (Dolphin может перезапустить поток).
    init(inputRate: Int, channels: Int, socketPath: String, outputRate: Int = 16_000,
         volume: Double = 1.0) throws {
        self.inputRate = inputRate
        self.inputChannels = max(1, min(2, channels))
        self.outputRate = outputRate
        endpoint = .unixSocket(path: socketPath)
        self.volume = max(0.0, min(4.0, volume))
        maxBufferedSamples = outputRate
        ring = SampleRing(capacity: maxBufferedSamples)
        resampler = LinearResampler(inputRate: inputRate, outputRate: outputRate)
        listenFD = try Self.makeListener(path: socketPath)
    }

    deinit {
        stop()
    }

    private static func makeListener(path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ProbeError.message("socket(AF_UNIX): \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw ProbeError.message("слишком длинный путь сокета: \(path)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = String(cString: strerror(errno))
            close(fd)
            throw ProbeError.message("bind \(path): \(error)")
        }
        guard listen(fd, 4) == 0 else {
            let error = String(cString: strerror(errno))
            close(fd)
            throw ProbeError.message("listen \(path): \(error)")
        }
        return fd
    }

    func start() {
        let thread = Thread { [weak self] in
            self?.readLoop()
        }
        thread.name = "pcm-input"
        thread.start()
    }

    func stop() {
        stateLock.lock()
        if stopRequested {
            stateLock.unlock()
            return
        }
        stopRequested = true
        let listener = listenFD
        let connection = connectionFD
        listenFD = -1
        connectionFD = -1
        stateLock.unlock()
        if connection >= 0 { close(connection) }
        if listener >= 0 { close(listener) }
    }

    private func readLoop() {
        switch endpoint {
        case .handle(let handle):
            readHandle(handle)
            stateLock.lock()
            ioFinished = true
            stateLock.unlock()
        case .unixSocket(let path):
            readSocket(path: path)
        }
    }

    private func readHandle(_ handle: FileHandle) {
        while true {
            let data: Data?
            do {
                data = try handle.read(upToCount: 4096)
            } catch {
                stateLock.lock()
                readError = error.localizedDescription
                stateLock.unlock()
                return
            }
            guard let data, !data.isEmpty else {
                return
            }
            // Файл читается мгновенно; притормаживаем чтение, чтобы не
            // потерять начало и играть в реальном времени.
            if throttleReads {
                waitForRoom()
            }
            ingest(data)
        }
    }

    private func waitForRoom() {
        while ring.available > maxBufferedSamples / 2 {
            stateLock.lock()
            let stopping = stopRequested
            stateLock.unlock()
            if stopping { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private func readSocket(path: String) {
        print("PCM-сокет: слушаю \(path), жду подключения Dolphin…")
        while true {
            stateLock.lock()
            let stopping = stopRequested
            stateLock.unlock()
            if stopping { return }

            let client = accept(listenFD, nil, nil)
            if client < 0 {
                stateLock.lock()
                let stopping = stopRequested
                stateLock.unlock()
                if stopping { return }
                if errno == EINTR { continue }
                stateLock.lock()
                readError = "accept: \(String(cString: strerror(errno)))"
                stateLock.unlock()
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }

            stateLock.lock()
            connectionFD = client
            stateLock.unlock()
            print("PCM-сокет: клиент подключён")
            readFramedSocket(client)
            close(client)

            stateLock.lock()
            connectionFD = -1
            stateLock.unlock()
            print("PCM-сокет: клиент отключился, жду следующего…")
        }
    }

    /// Читает двоичные блоки «D4P1» + rate + channels + frames из сокета.
    /// Если поток не начинается с сигнатуры — трактуем его как сырой PCM
    /// (например, для ручной проверки через `nc`).
    private func readFramedSocket(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            stateLock.lock()
            let stopping = stopRequested
            stateLock.unlock()
            if stopping { return }

            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { return }
            framedCarry.append(contentsOf: buffer[0 ..< count])
            parseFramedBlocks()
        }
    }

    private func parseFramedBlocks() {
        let headerSize = 16
        while framedCarry.count >= headerSize {
            guard framedCarry[0] == 0x44, framedCarry[1] == 0x34,
                  framedCarry[2] == 0x50, framedCarry[3] == 0x31 else {
                let raw = Data(framedCarry)
                framedCarry.removeAll()
                ingest(raw, rate: inputRate, channels: inputChannels)
                return
            }
            let rate = Int(UInt32(framedCarry[4]) | (UInt32(framedCarry[5]) << 8)
                | (UInt32(framedCarry[6]) << 16) | (UInt32(framedCarry[7]) << 24))
            let channels = Int(framedCarry[8])
            let frames = Int(UInt32(framedCarry[12]) | (UInt32(framedCarry[13]) << 8)
                | (UInt32(framedCarry[14]) << 16) | (UInt32(framedCarry[15]) << 24))
            let payloadBytes = frames * max(1, channels) * 2
            guard frames > 0, rate > 0, channels >= 1, channels <= 2,
                  framedCarry.count >= headerSize + payloadBytes else {
                return
            }
            let payload = Data(framedCarry[headerSize ..< headerSize + payloadBytes])
            framedCarry.removeFirst(headerSize + payloadBytes)
            ingest(payload, rate: rate, channels: channels)
        }
    }

    private func ingest(_ data: Data) {
        ingest(data, rate: inputRate, channels: inputChannels)
    }

    private func ingest(_ data: Data, rate: Int, channels: Int) {
        if rate != inputRate || max(1, min(2, channels)) != inputChannels {
            inputRate = rate
            inputChannels = max(1, min(2, channels))
            resampler = LinearResampler(inputRate: rate, outputRate: outputRate)
            carry.removeAll()
        }
        var bytes = carry
        bytes.append(contentsOf: data)
        let frameBytes = inputChannels * 2
        let frameCount = bytes.count / frameBytes
        let usedBytes = frameCount * frameBytes
        carry = Array(bytes[usedBytes...])
        guard frameCount > 0 else { return }

        var mono = [Float](repeating: 0, count: frameCount)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for i in 0 ..< frameCount {
                let offset = i * frameBytes
                if inputChannels == 1 {
                    mono[i] = Float(Int16(littleEndian: base.loadUnaligned(
                        fromByteOffset: offset, as: Int16.self)))
                } else {
                    let l = Int16(littleEndian: base.loadUnaligned(
                        fromByteOffset: offset, as: Int16.self))
                    let r = Int16(littleEndian: base.loadUnaligned(
                        fromByteOffset: offset + 2, as: Int16.self))
                    mono[i] = (Float(l) + Float(r)) * 0.5
                }
            }
        }

        var peak = 0
        for v in mono {
            let a = abs(Int(v))
            if a > peak { peak = a }
        }

        let resampled = resampler.process(mono)
        guard !resampled.isEmpty else { return }

        // Динамик DS4 моно и складывает каналы. Дублируем сигнал в оба
        // канала с половинной амплитудой: сумма даёт исходный уровень без
        // клиппинга. Громкость динамика задаётся отдельно (report 0x11).
        var stereo = [Int16](repeating: 0, count: resampled.count * 2)
        for i in 0 ..< resampled.count {
            let clamped = max(-32768.0, min(32767.0, Double(resampled[i]) * 0.5 * volume))
            let sample = Int16(clamped)
            stereo[i * 2] = sample
            stereo[i * 2 + 1] = sample
        }

        stateLock.lock()
        inputFrames += Int64(frameCount)
        inputSeconds += Double(frameCount) / Double(rate)
        outputFrames += Int64(resampled.count)
        if peak > peakLevel { peakLevel = peak }
        stateLock.unlock()

        ring.push(stereo)

        // Ограничение очереди: при переполнении выбрасываем самые старые
        // сэмплы, а не накапливаем задержку.
        if ring.available > maxBufferedSamples {
            let excess = ring.available - maxBufferedSamples
            _ = ring.pull(excess)
            stateLock.lock()
            overruns += 1
            droppedInputSamples += excess / 2
            stateLock.unlock()
        }
    }

    /// Автономная проверка входного тракта без устройства: читает весь
    /// вход, ресемплирует и возвращает длительность/пик на выходе.
    static func selftest(inputRate: Int, channels: Int, reader: FileHandle,
                         outputRate: Int) throws -> (inputFrames: Int, outputFrames: Int,
                                                     peak: Int, duration: Double) {
        let source = PcmStreamSource(inputRate: inputRate, channels: channels, reader: reader,
                                     outputRate: outputRate)
        source.throttleReads = false
        source.readHandle(reader)
        let inputFrames = Int(source.inputFrames)
        let outputFrames = Int(source.outputFrames)
        return (inputFrames, outputFrames, source.peakLevel,
                Double(outputFrames) / Double(outputRate))
    }

    /// Забирает 128 стерео-кадров. При недоборе подставляет тишину и
    /// увеличивает счётчик underrun.
    func nextFrame() -> (left: [Int16], right: [Int16]) {
        let (samples, underrun) = ring.pull(256)
        if underrun { underruns += 1 }
        var left = [Int16](repeating: 0, count: 128)
        var right = [Int16](repeating: 0, count: 128)
        for i in 0 ..< 128 {
            left[i] = samples[i * 2]
            right[i] = samples[i * 2 + 1]
        }
        return (left, right)
    }

    var bufferedFrames: Int {
        ring.available / 2
    }

    var bufferedSeconds: Double {
        Double(bufferedFrames) / Double(outputRate)
    }

    var finished: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return ioFinished && ring.available == 0
    }

    var errorDescription: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return readError
    }

    var overrunCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return overruns
    }
}
