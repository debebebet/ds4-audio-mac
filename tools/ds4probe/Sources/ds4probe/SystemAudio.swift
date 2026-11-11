// MARK: - Восстановление вывода системы

/// Путь, куда пишем «прежний» вывод системы, чтобы вернуть его позже.
enum DefaultOutputState {
    static var path: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("ds4probe-prev-output")
    }

    static func remember(_ id: AudioDeviceID) {
        try? Data("\(id)".utf8).write(to: URL(fileURLWithPath: path))
    }

    static func restore() -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8),
              let id = AudioDeviceID(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        let ok = AudioDevices.setDefaultOutput(id)
        try? FileManager.default.removeItem(atPath: path)
        if ok, let name = AudioDevices.name(of: id) {
            print("Вывод системы возвращён на «\(name)»")
        }
        return ok
    }
}

/// Обработчики Ctrl-C / SIGTERM: возвращают вывод системы и завершаются.
final class SignalRestore {
    private var sources: [DispatchSourceSignal] = []

    func install(restore: @escaping () -> Void) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                restore()
                exit(0)
            }
            source.resume()
            sources.append(source)
        }
    }
}

// MARK: - Захват системного аудио
//
// Чтобы DS4 стал «аудиоустройством системы» на macOS, используется
// собственный виртуальный loopback-драйвер «DualShock 4» (tools/ds4driver):
// система пишет в него, мы читаем его вход и отправляем в динамик контроллера.
//
// Цепочка:  система (QuickTime/Safari/музыка) → «DualShock 4» → наш tap
//            → ресемплинг 48 кГц → 16 кГц → SBC → HID-отчёты → динамик DS4.

import AVFoundation
import CoreAudio

// MARK: - Перечисление устройств CoreAudio

struct AudioInputDeviceInfo {
    let id: AudioDeviceID
    let name: String
    let inputChannels: Int
}

enum AudioDevices {
    /// Все устройства, у которых есть вход (в том числе виртуальные loopback).
    static func listInputs() -> [AudioInputDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let channels = inputChannelCount(id)
            guard channels > 0 else { return nil }
            return AudioInputDeviceInfo(id: id, name: name(of: id) ?? "Без имени",
                                        inputChannels: channels)
        }
    }

    static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfName: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cfName) == noErr else { return nil }
        return cfName as String
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Устройство вывода по умолчанию (то, куда играет система).
    static func defaultOutput() -> (id: AudioDeviceID, name: String)? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr else { return nil }
        return (id, name(of: id) ?? "?")
    }

    /// Громкость вывода устройства (0…1). У виртуальных устройств типа
    /// У виртуальных устройств (BlackHole, «DualShock 4») она по умолчанию
    /// может быть маленькой — из-за этого захваченный звук тихий.
    static func outputVolume(_ id: AudioDeviceID) -> Float? {
        for element in [kAudioObjectPropertyElementMain, UInt32(1), UInt32(2)] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            guard AudioObjectHasProperty(id, &address) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    @discardableResult
    static func setOutputVolume(_ id: AudioDeviceID, _ value: Float32) -> Bool {
        for element in [kAudioObjectPropertyElementMain, UInt32(1), UInt32(2)] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element)
            guard AudioObjectHasProperty(id, &address) else { continue }
            var v = value
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(id, &address, 0, nil, size, &v) == noErr {
                return true
            }
        }
        return false
    }

    /// Устройства вывода (те, куда можно играть).
    static func listOutputs() -> [AudioInputDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let channels = outputChannelCount(id)
            guard channels > 0 else { return nil }
            return AudioInputDeviceInfo(id: id, name: name(of: id) ?? "Без имени",
                                        inputChannels: channels)
        }
    }

    static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Сделать устройство выводом по умолчанию (системный звук пойдёт в него).
    @discardableResult
    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &device)
        return status == noErr
    }
}

// MARK: - Кольцевой буфер сэмплов

/// Кольцевой буфер интерливнутых Int16 (стерео) с фиксированной ёмкостью.
final class SampleRing {
    private var storage: [Int16]
    private var writeIndex = 0
    private var readIndex = 0
    private var count = 0
    private let lock = NSLock()
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        storage = [Int16](repeating: 0, count: capacity)
    }

    /// Положить сэмплы; при переполнении вытесняются самые старые.
    func push(_ samples: [Int16]) {
        lock.lock(); defer { lock.unlock() }
        var incoming = samples
        if incoming.count > capacity { incoming = Array(incoming.suffix(capacity)) }
        for v in incoming {
            storage[writeIndex] = v
            writeIndex = (writeIndex + 1) % capacity
            if count < capacity { count += 1 } else { readIndex = (readIndex + 1) % capacity }
        }
    }

    /// Забрать n сэмплов. Если данных не хватило — добор тишиной,
    /// флаг underrun сообщает о недоборе.
    func pull(_ n: Int) -> (samples: [Int16], underrun: Bool) {
        lock.lock(); defer { lock.unlock() }
        let available = count
        var out = [Int16](repeating: 0, count: n)
        var got = 0
        while got < n && count > 0 {
            out[got] = storage[readIndex]
            readIndex = (readIndex + 1) % capacity
            count -= 1
            got += 1
        }
        return (out, available < n)
    }

    var available: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    /// Выбросить накопленное. Нужно после пересоздания tap'а: в буфере лежит
    /// звук, записанный до переключения вывода, а играть его позже не надо.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        writeIndex = 0
        readIndex = 0
        count = 0
    }
}

// MARK: - Захват

/// Захват звука с аудиовхода системы через AVAudioEngine + ресемплинг в 16 кГц.
final class SystemAudioCapture {
    private var engine: AVAudioEngine
    private let ring: SampleRing
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    let deviceName: String
    private(set) var underruns = 0
    private(set) var capturedFrames = 0
    private(set) var peakLevel: Int = 0

    /// Линейное усиление захваченного сигнала (в системе вывод может быть
    /// тихим, а динамик DS4 хочет полную шкалу).
    var gain: Double = 1.0
    /// Куда сохранить захваченный звук (WAV) — для отладки.
    var dumpPath: String?
    private var dumpSamples: [Int16] = []
    /// Автоматическая нормализация уровня: подтянуть тихие источники к
    /// −3 дБFS и не дать громким обрезаться. Верхняя граница — `gain`.
    var autoLevel = true
    private let targetPeak: Double = 0.9      // −0.9 дБFS
    private var runningPeak: Double = 0.0

    /// Когда в последний раз приходил буфер из tap'а.
    ///
    /// Пока tap жив, колбэк вызывается постоянно — даже если звука нет,
    /// приходят буферы тишины. Поэтому пауза в колбэках однозначно означает,
    /// что входной audio unit пересоздан системой и tap умер.
    private let stateLock = NSLock()
    private var lastCallbackAt = Date()

    /// Сколько секунд тишины в колбэках считаем смертью tap'а.
    /// Обычно колбэк приходит каждые ~43 мс (2048 кадров при 48 кГц),
    /// так что полторы секунды — очень консервативный порог.
    private static let tapAliveTimeout: TimeInterval = 1.5

    init(device: AudioInputDeviceInfo, targetRate: Int) throws {
        deviceName = device.name
        ring = SampleRing(capacity: targetRate * 4)   // 4 секунды запаса
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(targetRate),
                                         channels: 2, interleaved: false) else {
            throw ProbeError.message("не удалось создать формат \(targetRate) Гц")
        }
        targetFormat = target

        engine = AVAudioEngine()
        try attachTap(to: engine, device: device)
    }

    /// Жив ли tap. Если нет — система пересоздала входной audio unit и
    /// прежний tap молча умер: приложение продолжает слать в контроллер
    /// тишину, а звука нет.
    var isTapAlive: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return Date().timeIntervalSince(lastCallbackAt) < Self.tapAliveTimeout
    }

    /// Поднимает tap на audio unit указанного устройства.
    private func attachTap(to engine: AVAudioEngine, device: AudioInputDeviceInfo) throws {
        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else {
            throw ProbeError.message("не удалось получить audio unit устройства ввода")
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(audioUnit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            throw ProbeError.message("не удалось выбрать устройство «\(device.name)» (OSStatus \(status))")
        }

        let inputFormat = input.inputFormat(forBus: 0)
        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw ProbeError.message("AVAudioConverter не поддерживает \(inputFormat)")
        }
        converter = conv

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
    }

    /// Пересоздать engine и tap на том же устройстве.
    ///
    /// Нужен после смены системного вывода: macOS пересоздаёт входной
    /// audio unit устройства, и прежний tap перестаёт получать буферы.
    /// Без пересоздания захват молча умирает, и в контроллер уходит тишина.
    func rebuild(device: AudioInputDeviceInfo) throws {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        let fresh = AVAudioEngine()
        try attachTap(to: fresh, device: device)
        engine = fresh
        engine.prepare()
        try engine.start()

        // В буфере лежит звук, записанный до переключения вывода.
        ring.clear()
        stateLock.lock()
        lastCallbackAt = Date()
        stateLock.unlock()
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        lastCallbackAt = Date()
        stateLock.unlock()

        guard let conv = converter else { return }
        let srcRate = buffer.format.sampleRate
        let ratio = srcRate > 0 ? targetFormat.sampleRate / srcRate : 1
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 128)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var error: NSError?
        var provided = false
        let status = conv.convert(to: out, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            if let error { print("[capture] ошибка конвертации: \(error.localizedDescription)") }
            return
        }
        guard let l = out.floatChannelData?[0], let r = out.floatChannelData?[1] else { return }
        let frames = Int(out.frameLength)
        var interleaved = [Int16](repeating: 0, count: frames * 2)
        // Уровень: мгновенный пик + медленный спад, чтобы не «качать» громкость.
        var instantPeak: Double = 0
        for i in 0 ..< frames {
            instantPeak = max(instantPeak, abs(Double(l[i])), abs(Double(r[i])))
        }
        runningPeak = max(instantPeak, runningPeak * 0.999)
        var effective = gain
        if autoLevel && runningPeak > 0.0002 {
            effective = min(gain, targetPeak / runningPeak)
        }
        for i in 0 ..< frames {
            let lv: Double = Double(l[i]) * 32767.0 * effective
            let rv: Double = Double(r[i]) * 32767.0 * effective
            interleaved[i * 2] = Int16(max(-32768, min(32767, Int(lv))))
            interleaved[i * 2 + 1] = Int16(max(-32768, min(32767, Int(rv))))
        }
        for v in interleaved {
            let a = v < 0 ? -Int(v) : Int(v)
            if a > peakLevel { peakLevel = a }
        }
        ring.push(interleaved)
        capturedFrames += frames
        if dumpPath != nil { dumpSamples.append(contentsOf: interleaved) }
    }

    /// Следующий кадр (128 сэмплов на канал). При недоборе — тишина:
    /// так DSP контроллера не сбрасывается (в эталоне nefarius так же:
    /// при недоборе в поток вставляются кадры тишины).
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

    /// Сохранить захваченный звук в WAV (16 кГц, стерео).
    func writeDump() {
        guard let path = dumpPath, !dumpSamples.isEmpty else { return }
        let wav = WavFile(sampleRate: Int(targetFormat.sampleRate), channels: 2, samples: dumpSamples)
        try? wav.write(to: path)
        print("Захват сохранён: \(path) (\(dumpSamples.count / 2) сэмплов)")
    }

    var bufferedSeconds: Double {
        Double(ring.available) / 2.0 / targetFormat.sampleRate
    }
}
