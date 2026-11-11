// ds4probe — зонд аудиопротокола DualShock 4 по Bluetooth.
//
// Задача: отправить контроллеру HID-репорты, в которых SBC-кадры несут
// синусоиду, и проверить, что динамик DS4 её играет.
//
// Протокол (подтверждён по живому HID-дескриптору DS4 v2 и по эталонной
// реализации nefarius/DS4AudioStreamer + abh1shekbana/DS4-Sound-Link):
//
//   Report 0x11 — «взвод» аудиоплоскости, 78 байт
//     [0]      = 0x11           Report ID
//     [1]      = 0xC0 | poll    флаги Bluetooth
//     [2]      = 0xA0 | 0xA2    режим аудиоплоскости
//     [3]      = 0xF3           маска валидности
//     [21..22] = VolumeLeft/Right
//     [23]     = VolumeMic
//     [24]     = VolumeSpeaker
//     [25]     = 0x85           handshake «защёлкивания» DSP-маршрутизации
//     [74..77] = CRC-32 (LE) поверх 0xA2 + report[0..73]
//
//   Report 0x17 — аудиокадры, 462 байта
//     [0]      = 0x17
//     [1]      = 0x40 | poll
//     [2]      = 0xA0 | 0xA2
//     [3..4]   = frameNumber (uint16 LE, инкремент на число кадров в репорте)
//     [5]      = target: 0x02 — встроенный динамик, 0x24 — 3.5 мм джек
//     [6..441] = N × SBC-кадр по 109 байт
//     [442..457] = нулевое дополнение
//     [458..461] = CRC-32 (LE) поверх 0xA2 + report[0..457]
//
//   Аналогично 0x14 (270 байт, 2 кадра) и 0x12 (142 байта, 1 кадр).

import Foundation
import IOKit
import IOKit.hid
import CSBC

// Журнал стримера должен попадать в GUI построчно. По умолчанию stdout при
// перенаправлении в канал буферизуется блоками по 4–8 КБ, и в журнале
// приложения строки появляются пачками с задержкой в минуты — а на
// заполненном буфере поток встаёт, потому что `print` блокируется.
setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - CRC-32

/// CRC-32 (IEEE 802.3, полином 0xEDB88320) с необязательным префиксом
/// транзакции Bluetooth HID (0xA2 для output-репортов, 0xA1 для input).
enum Ds4Crc32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var crc = UInt32(i)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
            return crc
        }
    }()

    static func compute(_ bytes: [UInt8], prefix: UInt8? = nil) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        if let prefix {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(prefix)) & 0xFF)]
        }
        for byte in bytes {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return ~crc
    }

    /// Записывает CRC в последние 4 байта буфера (little-endian).
    static func append(_ buffer: inout [UInt8], prefix: UInt8? = 0xA2) {
        let payload = Array(buffer[0 ..< buffer.count - 4])
        let crc = compute(payload, prefix: prefix)
        buffer[buffer.count - 4] = UInt8(crc & 0xFF)
        buffer[buffer.count - 3] = UInt8((crc >> 8) & 0xFF)
        buffer[buffer.count - 2] = UInt8((crc >> 16) & 0xFF)
        buffer[buffer.count - 1] = UInt8((crc >> 24) & 0xFF)
    }
}

// MARK: - Сборка репортов

enum Ds4Report {
    static let controlLength = 78
    static let controlID: UInt8 = 0x11

    /// Report 0x11 — «взвод» аудиоплоскости.
    static func control(target: UInt8,
                        volume: UInt8,
                        modeByte: UInt8,
                        handshake: UInt8,
                        lightbar: (r: UInt8, g: UInt8, b: UInt8) = (0x00, 0x00, 0x28),
                        pollRate: UInt8 = 0) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: controlLength)
        report[0] = controlID
        report[1] = 0xC0 | (pollRate & 0x0F)
        report[2] = modeByte
        report[3] = 0xF3
        // 6/7 — моторы, 8/9/10 — RGB подсветки, 11/12 — параметры мигания.
        // ВАЖНО: контроллер применяет отчёт целиком, поэтому нули в [8..10]
        // гасят подсветку — это подтверждено на живом устройстве.
        report[8] = lightbar.r
        report[9] = lightbar.g
        report[10] = lightbar.b
        // 21/22 — левый/правый канал, 23 — микрофон, 24 — встроенный динамик
        let toSpeaker = (target == 0x02)
        report[21] = toSpeaker ? 0 : volume
        report[22] = toSpeaker ? 0 : volume
        report[23] = 0
        report[24] = toSpeaker ? volume : 0
        report[25] = handshake
        Ds4Crc32.append(&report, prefix: 0xA2)
        return report
    }

    /// Полная длина репорта — из живого HID-дескриптора DS4 v2:
    /// 0x11 → 78, 0x12 → 142, 0x13 → 206, 0x14 → 270, 0x15 → 334,
    /// 0x16 → 398, 0x17 → 462, 0x18 → 526, 0x19 → 547 (потолок BT-репорта).
    static func totalLength(reportID: UInt8) -> Int {
        switch reportID {
        case 0x11: return 78
        case 0x12: return 142
        case 0x13: return 206
        case 0x14: return 270
        case 0x15: return 334
        case 0x16: return 398
        case 0x17: return 462
        case 0x18: return 526
        case 0x19: return 547
        default: return 78
        }
    }

    /// Report 0x17 / 0x14 / 0x12 — аудиокадры.
    ///
    /// Раскладка (по эталонной реализации nefarius/DS4AudioStreamer,
    /// подтверждённой константами шипной сборки DS4SoundLink):
    ///   [0]      = Report ID
    ///   [1]      = 0x40 | poll
    ///   [2]      = 0xA0 | 0xA2
    ///   [3..4]   = frameNumber (uint16 LE)
    ///   [5]      = target (0x02 — динамик, 0x24 — джек)
    ///   [6..]    = N × SBC-кадр по 109 байт
    ///   [..len-4] = CRC-32 (LE) поверх 0xA2 + report[0 ..< len-4]
    static func stream(reportID: UInt8,
                       frameNumber: UInt16,
                       frames: [[UInt8]],
                       target: UInt8,
                       modeByte: UInt8,
                       audioOffset: Int = 6,
                       pollRate: UInt8 = 0) -> [UInt8] {
        let total = totalLength(reportID: reportID)
        let audioEnd = audioOffset + frames.reduce(0) { $0 + $1.count }
        precondition(audioEnd <= total - 4,
                     "frames не помещаются в репорт 0x\(String(format: "%02X", reportID)): \(audioEnd) > \(total - 4)")
        var report = [UInt8](repeating: 0, count: total)
        report[0] = reportID
        report[1] = 0x40 | (pollRate & 0x0F)
        report[2] = modeByte
        report[3] = UInt8(frameNumber & 0xFF)
        report[4] = UInt8((frameNumber >> 8) & 0xFF)
        report[5] = target
        var offset = audioOffset
        for frame in frames {
            precondition(frame.count <= total - 4 - offset,
                         "SBC-кадр не помещается в репорт")
            report.replaceSubrange(offset ..< offset + frame.count, with: frame)
            offset += frame.count
        }
        Ds4Crc32.append(&report, prefix: 0xA2)
        return report
    }
}

// MARK: - SBC-энкодер

/// Обёртка над libsbc 2.1: 32 кГц, 8 подполос, 16 блоков, Joint Stereo, SNR, bitpool 48.
///
/// Конфигурация задаётся через sbc_configure() — расширение вендоренной копии
/// libsbc: в стоковой 2.1 публичных сеттеров нет, есть только A2DP-инициализация.
final class SbcFrameEncoder {
    private let state: UnsafeMutablePointer<sbc_t>
    let frameLength: Int
    let codeSize: Int

    let channels: Int
    let allocationName: String

    init(sampleRate: Int32 = 32_000, bitpool: Int32 = 48, mono: Bool = false,
         dual: Bool = false, allocation: Int32 = SBC_AM_SNR) {
        state = .allocate(capacity: 1)
        state.initialize(to: sbc_t())

        let initResult = sbc_init(state, 0)
        precondition(initResult == 0, "sbc_init вернул \(initResult)")

        let freq: Int32 = sampleRate == 16_000 ? SBC_FREQ_16000 : SBC_FREQ_32000
        let mode: Int32 = mono ? SBC_MODE_MONO : (dual ? SBC_MODE_DUAL_CHANNEL : SBC_MODE_JOINT_STEREO)
        // Число блоков всегда 16: в этом кодеке бит на сэмпл = bitpool/8,
        // то есть битрейт не зависит от числа блоков, а накладные расходы
        // на кадр (13 B) растут при меньших кадрах.
        let blk: Int32 = SBC_BLK_16
        let cfg = sbc_configure(state, freq, mode, allocation,
                                SBC_SB_8, blk, bitpool)
        precondition(cfg == 0, "sbc_configure вернул \(cfg)")

        channels = mono ? 1 : 2
        frameLength = Int(sbc_get_frame_length(state))
        codeSize = Int(sbc_get_codesize(state))
        allocationName = allocation == SBC_AM_LOUDNESS ? "loudness" : "snr"
    }

    deinit {
        sbc_finish(state)
        state.deinitialize(count: 1)
        state.deallocate()
    }

    /// Кодирует 128 сэмплов на канал (интерливнутые Int16 LE) в один SBC-кадр.
    func encode(left: [Int16], right: [Int16]) -> [UInt8] {
        precondition(left.count >= 128 && right.count >= 128)
        var pcm = [Int16](repeating: 0, count: 256)
        if channels == 1 {
            for i in 0 ..< 128 { pcm[i] = left[i] }
        } else {
            for i in 0 ..< 128 {
                pcm[i * 2] = left[i]
                pcm[i * 2 + 1] = right[i]
            }
        }
        var out = [UInt8](repeating: 0, count: frameLength)
        var written: Int = 0
        let rc = pcm.withUnsafeBufferPointer { pcmPtr -> Int in
            out.withUnsafeMutableBufferPointer { outPtr -> Int in
                sbc_encode(state,
                           pcmPtr.baseAddress,
                           pcmPtr.count * 2,
                           outPtr.baseAddress,
                           outPtr.count,
                           &written)
            }
        }
        precondition(rc >= 0 && written == frameLength,
                     "sbc_encode вернул \(rc), записано \(written) из \(frameLength)")
        return out
    }
}

// MARK: - Устройство

/// Обёртка над IOHIDManager: поиск DS4 по VID/PID и транспорту, отправка output-репортов.
final class Ds4Device {
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private(set) var inputReports: [UInt8: [UInt8]] = [:]
    private let inputLock = NSLock()
    private var inputCount = 0
    private var inputTimestamps: [Date] = []
    /// История *изменений* входящего репорта по ID: DS4 шлёт обратно
    /// аудио-статус в input-отчётах 0x11…0x18 (они двунаправленные в
    /// HID-дескрипторе), поэтому по диффу можно понять смысл handshake.
    private var inputHistory: [UInt8: [[UInt8]]] = [:]

    /// Печатает все HID-устройства системы — диагностика, когда цель не найдена.
    static func listAllHidDevices() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [:] as CFDictionary)
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            print("не удалось получить список HID-устройств")
            return
        }
        print("HID-устройств в системе: \(set.count)")
        for device in set {
            let vid = (IOHIDDeviceGetProperty(device, "VendorID" as CFString) as? NSNumber)?.intValue ?? 0
            let pid = (IOHIDDeviceGetProperty(device, "ProductID" as CFString) as? NSNumber)?.intValue ?? 0
            let product = (IOHIDDeviceGetProperty(device, "Product" as CFString) as? String) ?? "?"
            let transport = (IOHIDDeviceGetProperty(device, "Transport" as CFString) as? String) ?? "?"
            print(String(format: "  %04X:%04X  %-28@  transport=%@",
                         vid, pid, product as NSString, transport as NSString))
        }
    }

    init(vendorID: Int, productID: Int, requireBluetooth: Bool, transportFilter: String = "", waitSeconds: Double = 0, registerInput: Bool = true) throws {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching: CFDictionary = [
            "VendorID": vendorID,
            "ProductID": productID,
        ] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw ProbeError.message("IOHIDManagerOpen: \(openResult)")
        }

        // Устройство может появиться не сразу: после сна контроллера канал HID
        // поднимается заново. Ждём до таймаута.
        let deadline = Date().addingTimeInterval(waitSeconds)
        var candidates: Set<IOHIDDevice> = []
        repeat {
            candidates = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
            if !candidates.isEmpty { break }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.5)
        } while true

        guard !candidates.isEmpty else {
            Self.listAllHidDevices()
            throw ProbeError.message("Устройство \(String(format: "0x%04X:0x%04X", vendorID, productID)) не найдено")
        }
        let set = candidates

        // Выбор транспорта: по умолчанию Bluetooth (USB-подключение не даёт
        // аудио в динамик), но можно форсировать любой.
        let wanted = transportFilter
        let filtered = set.filter { device in
            guard let t = Self.transport(of: device) else { return false }
            return wanted.isEmpty || t.lowercased().contains(wanted.lowercased())
        }
        guard let chosen = filtered.first else {
            let found = set.map { "\(Self.transport(of: $0) ?? "?")" }.joined(separator: ", ")
            throw ProbeError.message("Устройство не найдено для транспорта \(wanted.isEmpty ? "любой" : wanted) (найдено: \(found))")
        }
        device = chosen

        if registerInput {
        IOHIDManagerRegisterInputReportCallback(manager, { context, result, sender, type, reportID, report, length in
            guard let context else { return }
            let probe = Unmanaged<Ds4Device>.fromOpaque(context).takeUnretainedValue()
            var bytes = [UInt8](repeating: 0, count: length)
            for i in 0 ..< length { bytes[i] = report[i] }
            probe.inputLock.lock()
            let key = UInt8(reportID & 0xFF)
            if probe.inputReports[key] != bytes {
                probe.inputReports[key] = bytes
                probe.inputHistory[key, default: []].append(bytes)
            }
            probe.inputCount += 1
            probe.inputTimestamps.append(Date())
            if probe.inputTimestamps.count > 500 { probe.inputTimestamps.removeFirst() }
            probe.inputLock.unlock()
            _ = result
            _ = sender
            _ = type
        }, Unmanaged.passUnretained(self).toOpaque())
        }

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    private static func transport(of device: IOHIDDevice) -> String? {
        guard let raw = IOHIDDeviceGetProperty(device, "Transport" as CFString),
              CFGetTypeID(raw as CFTypeRef) == CFStringGetTypeID() else { return nil }
        return (raw as! CFString) as String
    }

    var product: String {
        guard let raw = IOHIDDeviceGetProperty(device, "Product" as CFString),
              CFGetTypeID(raw as CFTypeRef) == CFStringGetTypeID() else { return "?" }
        return (raw as! CFString) as String
    }

    /// Отправляет output-репорт. Report ID обязан быть первым байтом буфера —
    /// этого требует контракт IOHIDDeviceSetReport в IOKit.
    ///
    /// Таймаут обязателен: если контроллер отключился (Bluetooth-простой или
    /// разрядка), `IOHIDDeviceSetReport` блокируется **бесконечно** — у IOKit
    /// нет собственного таймаута. Поэтому запись уходит в отдельный поток, а
    /// вызывающий ждёт семафор с дедлайном.
    func send(_ report: [UInt8], stripID: Bool = false, timeout: TimeInterval = 2.0) throws {
        let reportID = CFIndex(report[0])
        var payload = report
        if stripID { payload.removeFirst() }
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = payload.withUnsafeBufferPointer { buf -> IOReturn in
                guard let base = buf.baseAddress else { return kIOReturnBadArgument }
                return IOHIDDeviceSetReport(self.device,
                                           kIOHIDReportTypeOutput,
                                           reportID,
                                           base,
                                           CFIndex(payload.count))
            }
            box.result = result
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            throw ProbeError.message("таймаут записи отчёта (\(Int(timeout * 1000)) мс) — устройство, вероятно, отключилось")
        }
        guard box.result == kIOReturnSuccess else {
            throw ProbeError.message("IOHIDDeviceSetReport: \(box.result)")
        }
    }

    /// Обёртка для результата из другого потока (Swift 5 — без строгих
    /// проверок конкурентности, запись происходит до сигнала семафора).
    final class ResultBox {
        var result: IOReturn = kIOReturnError
    }

    /// Асинхронная отправка: IOHIDDeviceSetReportWithCallback не блокирует
    /// вызывающий поток — критично, потому что синхронный вариант на Bluetooth
    /// висит ~90 мс на каждом репорте.
    func sendAsync(_ report: [UInt8],
                   stripID: Bool = false,
                   timeout: TimeInterval = 2.0,
                   completion: @escaping (IOReturn, TimeInterval) -> Void) {
        let reportID = CFIndex(report[0])
        var payload = report
        if stripID { payload.removeFirst() }
        let context = Unmanaged.passRetained(AsyncContext(completion: completion)).toOpaque()
        payload.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            IOHIDDeviceSetReportWithCallback(device,
                                             kIOHIDReportTypeOutput,
                                             reportID,
                                             base,
                                             CFIndex(payload.count),
                                             timeout,
                                             { context, result, _, _, _, _, _ in
                                                 guard let context else { return }
                                                 let ctx = Unmanaged<AsyncContext>.fromOpaque(context).takeRetainedValue()
                                                 ctx.completion(result, Date().timeIntervalSince(ctx.started) * 1000)
                                             },
                                             context)
        }
    }

    /// Контекст асинхронного callback'а: C-указатель не может захватывать
    /// переменные Swift, поэтому всё состояние живёт здесь.
    final class AsyncContext {
        let started = Date()
        let completion: (IOReturn, TimeInterval) -> Void
        init(completion: @escaping (IOReturn, TimeInterval) -> Void) {
            self.completion = completion
        }
    }

    func startInputReporting() {
        IOHIDManagerOpen(self.manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Всего принято входящих репортов — для оконной оценки темпа.
    func inputTotal() -> Int {
        inputLock.lock(); defer { inputLock.unlock() }
        return inputCount
    }

    /// Темп входящих input-репортов (обратный канал).
    func inputRate() -> (count: Int, perSecond: Double) {
        inputLock.lock(); defer { inputLock.unlock() }
        guard let first = inputTimestamps.first, let last = inputTimestamps.last,
              last > first else { return (inputCount, 0) }
        let span = last.timeIntervalSince(first)
        return (inputCount, span > 0 ? Double(inputCount) / span : 0)
    }

    func snapshotInputReports() -> [UInt8: [UInt8]] {
        inputLock.lock(); defer { inputLock.unlock() }
        return inputReports
    }

    /// Все изменения входящего репорта с указанным ID, по порядку.
    func history(for id: UInt8) -> [[UInt8]] {
        inputLock.lock(); defer { inputLock.unlock() }
        return inputHistory[id] ?? []
    }
}

enum ProbeError: Error {
    case message(String)
}

// MARK: - Тон

/// Длительность одного SBC-кадра в миллисекундах: 128 сэмплов на канал.
func frameDurationMs(sampleRate: Int) -> Double {
    Double(128) * 1000.0 / Double(sampleRate)
}

/// Генератор синусоиды; амплитуда ограничена потолком −1.41 dBFS (0.85),
/// иначе встроенный SBC-декодер DS4 трещит на ВЧ.
///
/// Важно: динамик DS4 моно, значит контроллер складывает L и R. Если каналы
/// одинаковые, сумма вдвое больше исходного сигнала и ЦАП клиппит — это
/// кандидат на источник щелчков. Правый канал можно задать отдельно
/// (`--freq-r`, `--mute-right`) или снизить общую амплитуду (`--tone-amp`).
struct ToneGenerator {
    let frequency: Double
    let sampleRate: Double
    let amplitude: Double
    var rightFrequency: Double
    var rightAmplitude: Double
    private var phase: Double = 0
    private var rightPhase: Double = 0

    mutating func nextFrame() -> (left: [Int16], right: [Int16]) {
        var left = [Int16](repeating: 0, count: 128)
        var right = [Int16](repeating: 0, count: 128)
        let step = 2.0 * Double.pi * frequency / sampleRate
        let rightStep = 2.0 * Double.pi * rightFrequency / sampleRate
        for i in 0 ..< 128 {
            let value = amplitude * sin(phase)
            phase += step
            if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
            let sample = Int16(max(-32768, min(32767, Int32(value * 32767.0))))
            left[i] = sample

            let rvalue = rightAmplitude * sin(rightPhase)
            rightPhase += rightStep
            if rightPhase > 2.0 * Double.pi { rightPhase -= 2.0 * Double.pi }
            let rsample = Int16(max(-32768, min(32767, Int32(rvalue * 32767.0))))
            right[i] = rsample
        }
        return (left, right)
    }
}

// MARK: - DSP-конфигурация

func makeDspConfig(_ options: Options) -> DspConfig {
    var config = DspConfig()
    config.sampleRate = options.sampleRate
    config.lowpassHz = options.lowpassHz
    config.highpassHz = options.highpassHz
    config.midBoostDb = options.midBoostDb
    config.monoPre = options.monoPre
    config.compressMaxGain = options.compressGain
    config.normalize = options.normalize
    config.normalizeByChannelPeak = options.normalizeByPeak
    config.limiterCeilingDb = options.limitDb
    config.normalizeTarget = 0.999
    config.extraGain = options.gain
    config.downsampleHoldHz = options.downsampleHoldHz
    config.bitcrushBits = options.bitcrushBits

    return config
}

func dspDescription(_ config: DspConfig) -> String {
    var parts: [String] = []
    parts.append(config.monoPre ? "mono-pre" : "stereo")
    if let hp = config.highpassHz {
        parts.append(String(format: "HP %.0f Гц/2-й", hp))
    }
    if let lp = config.lowpassHz {
        parts.append(String(format: "LP %.0f Гц/4-й", lp))
    }
    if abs(config.midBoostDb) > 0.001 {
        parts.append(String(format: "mid +%.1f дБ@2кГц Q0.8", config.midBoostDb))
    }
    if config.compressMaxGain > 1 {
        parts.append(String(format: "comp ×%.1f", config.compressMaxGain))
    }
    if config.normalize {
        parts.append(config.normalizeByChannelPeak
                     ? String(format: "norm канал→%.1f", dbfs(config.normalizeTarget))
                     : String(format: "norm L+R→%.1f", dbfs(config.normalizeTarget)))
    }
    parts.append(String(format: "limiter %.1f дБFS", config.limiterCeilingDb))
    if let hold = config.downsampleHoldHz {
        parts.append(String(format: "hold %.0f Гц", hold))
    }
    if let bits = config.bitcrushBits {
        parts.append("bitcrush \(bits) бит TPDF")
    }
    return parts.joined(separator: ", ")
}

func peakLog(_ label: String, _ value: Double) -> String {
    String(format: "%@ %.1f дБFS", label, dbfs(value))
}

struct PreparedPlayback {
    let inputPeakChannel: Double
    let inputPeakSum: Double
    let processed: WavFile
    let frames: [(left: [Int16], right: [Int16])]
}

/// Загрузка --play: afconvert при необходимости, ресемплинг в rate SBC,
/// затем весь DSP-тракт целым файлом. Возвращает готовые кадры для кодера.
func preparePlayback(path: String, options: Options,
                     saveProcessed: String?) throws -> PreparedPlayback {
    // Не-WAV (mp3 и прочее) конвертируем системным afconvert во временный WAV.
    var sourcePath = path
    if !WavFile.isWav(path: path) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ds4play-\(UUID().uuidString).wav").path
        let conv = Process()
        conv.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        conv.arguments = ["-f", "WAVE", "-d", "LEI16@\(options.sampleRate)",
                          "-c", "2", path, tmp]
        try conv.run()
        conv.waitUntilExit()
        if conv.terminationStatus == 0 {
            sourcePath = tmp
            print("Конвертировал \(path) → WAV \(options.sampleRate) Гц (afconvert)")
        } else {
            print("Не удалось сконвертировать \(path) — пробую как есть")
        }
    }
    var wav = try WavFile.load(path: sourcePath)
    if options.trimSilence { wav = wav.trimmedSilence() }
    let (decodedLeft, decodedRight) = wav.decodedStereo(targetRate: options.sampleRate)
    guard !decodedLeft.isEmpty else {
        throw ProbeError.message("файл пуст после ресемплинга")
    }

    let config = makeDspConfig(options)
    let result = OfflineAudioProcessor.process(left: decodedLeft, right: decodedRight,
                                               config: config)
    let processedWav = WavFile.stereo(sampleRate: options.sampleRate,
                                      left: result.left, right: result.right)
    if let savePath = saveProcessed {
        try processedWav.write(to: savePath)
        print("  обработанный файл сохранён: \(savePath)")
    }

    var frames: [(left: [Int16], right: [Int16])] = []
    frames.reserveCapacity(result.left.count / 128)
    var pos = 0
    while pos + 128 <= result.left.count {
        frames.append((Array(result.left[pos ..< pos + 128]),
                       Array(result.right[pos ..< pos + 128])))
        pos += 128
    }
    print("DSP: \(dspDescription(config))")
    print("  вход:  \(peakLog("канал", result.peaks.inputChannel)), "
          + "\(peakLog("L+R", result.peaks.inputSum))")
    print("  фильтры: \(peakLog("канал", result.peaks.afterFiltersChannel)), "
          + "\(peakLog("L+R", result.peaks.afterFiltersSum))"
          + (result.midBoostSafetyGain < 1
             ? String(format: " (защита от клиппинга ×%.3f)", result.midBoostSafetyGain) : ""))
    if config.compressMaxGain > 1 {
        print("  компрессия: \(peakLog("канал", result.peaks.afterCompressionChannel)), "
              + "\(peakLog("L+R", result.peaks.afterCompressionSum))")
    }
    print("  нормализация: \(peakLog("канал", result.peaks.afterNormalizationChannel)), "
          + "\(peakLog("L+R", result.peaks.afterNormalizationSum))"
          + String(format: " (gain ×%.3f)", result.normalizationGain))
    print("  лимитер: \(peakLog("канал", result.peaks.afterLimiterChannel)), "
          + "\(peakLog("L+R", result.peaks.afterLimiterSum))")
    print("  выход: \(peakLog("канал", result.peaks.outputChannel)), "
          + "\(peakLog("L+R", result.peaks.outputSum)), кадров \(frames.count)")
    return PreparedPlayback(inputPeakChannel: result.peaks.inputChannel,
                            inputPeakSum: result.peaks.inputSum,
                            processed: processedWav,
                            frames: frames)
}

// MARK: - CLI

struct Options {
    var vendorID = 0x054C
    var productID = 0x09CC
    var reportID: UInt8 = 0x18
    var target: UInt8 = 0x02
    var modeByte: UInt8 = 0xA0
    var handshake: UInt8 = 0x85
    var volume: UInt8 = 0x4F   // 100 % от MaxHardwareVolume = 0x4F (79)
    var pollRate: UInt8 = 0
    var bitpool: Int32 = 12
    var frequency: Double = 1000
    /// Частота тона в правом канале (0 = как в левом). Нужно, чтобы проверить
    /// клиппинг при сложении каналов в моно-динамик DS4.
    var frequencyR: Double = 0
    /// Правый канал тишины: сумма L+R не клиппит.
    var muteRight = false
    /// Амплитуда теста (по умолчанию 0.85 = −1.41 dBFS).
    var toneAmp: Double = 0.85
    var seconds: Double = 3
    /// Задан ли `--seconds` явно (для PCM-режима по умолчанию ждём EOF).
    var secondsSpecified = false
    var stripID = false
    var dry = false
    var selftest = false
    var dumpPath: String?
    var requireBluetooth = true
    var transport: String = "bluetooth"
    var waitSeconds: Double = 0
    var listOnly = false
    var paceMs: Double = 0
    var asyncSend = false
    var maxInFlight = 4
    var lightbar: (UInt8, UInt8, UInt8) = (0x00, 0x00, 0x28)
    var mono = false
    /// Dual channel (два независимых канала) вместо joint stereo.
    var dual = false
    /// Частота дискретизации SBC: 32000 или 16000.
    var sampleRate: Int = 16_000
    /// WAV-файл для проигрывания вместо тона.
    var playPath: String?
    /// Смена громкости по ходу: через сколько секунд и на что (0xFF — отключить).
    var volumeChangeAt: Double = -1
    var volumeChangeTo: UInt8 = 0
    /// Файл с громкостью для GUI (строка «0x18»). Опрашивается на лету:
    /// при изменении зонд переотправляет control-отчёт 0x11.
    var volumeFile: String?
    /// Пауза после «взвода» (0x11) перед первым аудиоотчётом, мс.
    var armDelayMs: Double = 250
    /// Нормализовать громкость файла (по умолчанию включено).
    var normalize = true
    /// Нормализовать по пику канала вместо пика суммы каналов (старый режим).
    var normalizeByPeak = false
    /// Обрезать тишину в начале и конце файла.
    var trimSilence = false
    /// Компрессия динамики: максимальное поднятие тихих участков.
    var compressGain: Double = 0
    /// ФНЧ 4-го порядка (два бикуада Баттерворта), 0/выкл.
    var lowpassHz: Double?
    /// ФВЧ 2-го порядка (бикуад Баттерворта), 0/выкл.
    var highpassHz: Double?
    /// Пиковый EQ на 2 кГц, Q 0.8.
    var midBoostDb: Double = 0
    /// Свести L/R в моно до кодера (по умолчанию включено).
    var monoPre = true
    /// Метод распределения бит SBC: snr | loudness.
    var allocation = "snr"
    /// Потолок лимитера, дБFS. Выше −1.4 поднимать нельзя.
    var limitDb: Double = -1.4
    /// Sample-and-hold: удержание сэмпла с частотой N Гц, поток остаётся 16 кГц.
    var downsampleHoldHz: Double?
    /// Квантование амплитуды до N бит с TPDF-дизерингом.
    var bitcrushBits: Int?
    /// Только прогнать --play через DSP и сохранить результат, без DS4.
    var processOnly = false
    /// Сохранить обработанный WAV (после обрезки/компрессии/нормализации).
    var saveProcessed: String?
    /// Зацикливать файл. По умолчанию — нет: переход конец→начало даёт
    /// щелчок, который слышно как «прерывание».
    var loop = false
    /// Дополнительное линейное усиление файла.
    var gain: Double = 1.0
    var audioOffset = 6
    var framesPerReportOverride = 0
    var burst = 1
    var noInput = false
    var inputOnly = false
    /// ID входящего репорта для слежения за изменениями байтов.
    var watchInputID: UInt8?
    /// Отправить только 0x11 (взвод/разоружение), без аудиопотока.
    var armOnly = false
    /// Вообще ничего не отправлять (только наблюдение).
    var noArm = false
    /// Сколько раз повторно отправить 0x11 (проверка «commit-секунд»).
    var armRepeat = 1
    /// Отправлять без пауз между отчётами (проверка пакетной доставки).
    var unpaced = false
    /// Рабочий профиль DS4: 16 кГц, joint, bitpool 12, репорт 0x18.
    var native = false
    /// Режим системного аудио: захват с входа виртуального устройства
    /// «DualShock 4» (или другого loopback) в динамик DS4.
    var systemAudio = false
    /// Имя устройства захвата (по умолчанию — «DualShock 4», затем BlackHole,
    /// иначе первый вход).
    var captureDevice: String?
    /// Переключить вывод системы на устройство захвата.
    var setDefaultOutput = false
    /// Только показать список аудиоустройств.
    var listAudioDevices = false
    /// Вернуть вывод системы на устройство, которое было до переключения.
    var restoreOutput = false
    /// Усиление захваченного системного аудио. Системный звук приходит с
    /// уровнем самого файла (−20 дБFS у boot-саунда) — без усиления динамик
    /// DS4 его практически не слышит. 4.0 = +12 дБ, 32.0 = максимум AGC.
    var captureGain: Double = 16.0
    /// Автонормализация уровня захвата (AGC с ограничителем).
    var captureAutoLevel = true
    /// Имя устройства вывода системы, на которое надо переключиться.
    var outputDevice: String?
    /// Сохранить захваченный системный звук в WAV (отладка).
    var captureDump: String?
    /// Потоковый PCM-вход: сырые s16le сэмплы из stdin.
    var pcmStdin = false
    /// Потоковый PCM-вход из файла (тот же формат, что stdin).
    var pcmFile: String?
    /// Unix domain socket для PCM-входа (предпочтительно для Dolphin).
    var pcmSocket: String?
    /// Частота PCM-входа.
    var pcmRate = 16_000
    /// Каналов во входном PCM: 1 или 2.
    var pcmChannels = 1
    /// Дополнительное усиление PCM-входа (1.0 = без изменений).
    var pcmVolume = 1.0
    /// Автономная проверка PCM-тракта (без DS4).
    var pcmSelftest = false
}

/// Разбор hex-числа с необязательным префиксом 0x.
func parseHex8(_ text: String) -> UInt8? {
    let cleaned = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
    return UInt8(cleaned, radix: 16)
}

/// Разбор числа-байта: «0x..» — hex, чистые цифры — десятичное,
/// иначе (например «4F») — hex.
func parseByte(_ text: String) -> UInt8? {
    let cleaned = text.trimmingCharacters(in: .whitespaces)
    if cleaned.lowercased().hasPrefix("0x") { return parseHex8(cleaned) }
    if let d = UInt8(cleaned) { return d }
    return parseHex8(cleaned)
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        func next() -> String {
            guard !args.isEmpty else { fatalError("не хватает значения для \(arg)") }
            return args.removeFirst()
        }
        switch arg {
        case "--vid": options.vendorID = Int(next(), radix: 16) ?? options.vendorID
        case "--pid": options.productID = Int(next(), radix: 16) ?? options.productID
        case "--report": options.reportID = parseHex8(next()) ?? options.reportID
        case "--target": options.target = next() == "jack" ? 0x24 : 0x02
        case "--mode": options.modeByte = parseHex8(next()) ?? options.modeByte
        case "--handshake": options.handshake = parseHex8(next()) ?? options.handshake
        case "--volume": options.volume = parseByte(next()) ?? options.volume
        case "--poll": options.pollRate = UInt8(next()) ?? options.pollRate
        case "--bitpool": options.bitpool = Int32(next()) ?? options.bitpool
        case "--freq": options.frequency = Double(next()) ?? options.frequency
        case "--freq-r": options.frequencyR = Double(next()) ?? options.frequencyR
        case "--mute-right": options.muteRight = true
        case "--tone-amp": options.toneAmp = Double(next()) ?? options.toneAmp
        case "--seconds":
            options.seconds = Double(next()) ?? options.seconds
            options.secondsSpecified = true
        case "--strip-id": options.stripID = true
        case "--dry": options.dry = true
        case "--selftest": options.selftest = true
        case "--any-transport": options.requireBluetooth = false
        case "--transport": options.transport = next(); options.requireBluetooth = false
        case "--rgb":
            let parts = next().split(separator: ",").compactMap { UInt8($0, radix: 16) }
            if parts.count == 3 { options.lightbar = (parts[0], parts[1], parts[2]) }
        case "--mono": options.mono = true
        case "--dual": options.dual = true
        case "--rate": options.sampleRate = (Int(next()) ?? 32000) == 16000 ? 16_000 : 32_000
        case "--play": options.playPath = next()
        case "--arm-delay": options.armDelayMs = Double(next()) ?? options.armDelayMs
        case "--normalize": options.normalize = true
        case "--normalize-peak": options.normalizeByPeak = true
        case "--no-normalize": options.normalize = false
        case "--trim-silence": options.trimSilence = true
        case "--compress": options.compressGain = Double(next()) ?? 8
        case "--lowpass": options.lowpassHz = Double(next())
        case "--highpass": options.highpassHz = Double(next())
        case "--mid-boost": options.midBoostDb = Double(next()) ?? options.midBoostDb
        case "--mono-pre": options.monoPre = true
        case "--no-mono-pre": options.monoPre = false
        case "--allocation": options.allocation = next().lowercased()
        case "--limit": options.limitDb = Double(next()) ?? options.limitDb
        case "--bitcrush": options.bitcrushBits = Int(next()) ?? options.bitcrushBits
        case "--downsample-hold": options.downsampleHoldHz = Double(next())
        case "--process-only": options.processOnly = true
        case "--save-processed": options.saveProcessed = next()
        case "--loop": options.loop = true
        case "--gain": options.gain = Double(next()) ?? options.gain
        case "--volume-change":
            // формат: <секунды>:<hex-громкость>
            let raw = next()
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                options.volumeChangeAt = Double(parts[0]) ?? -1
                options.volumeChangeTo = parseByte(parts[1]) ?? 0
            }
        case "--volume-file": options.volumeFile = next()
        case "--offset": options.audioOffset = Int(next()) ?? options.audioOffset
        case "--frames": options.framesPerReportOverride = Int(next()) ?? options.framesPerReportOverride
        case "--burst": options.burst = Int(next()) ?? options.burst
        case "--no-input": options.noInput = true
        case "--input-only": options.inputOnly = true
        case "--watch-input": options.watchInputID = parseHex8(next())
        case "--arm-only": options.armOnly = true
        case "--no-arm": options.noArm = true
        case "--arm-repeat": options.armRepeat = max(1, Int(next()) ?? 1)
        case "--unpaced": options.unpaced = true
        case "--native": options.native = true
        case "--wait": options.waitSeconds = Double(next()) ?? options.waitSeconds
        case "--pace": options.paceMs = Double(next()) ?? options.paceMs
        case "--list": options.listOnly = true
        case "--system-audio": options.systemAudio = true
        case "--capture-device": options.captureDevice = next()
        case "--set-default-output": options.setDefaultOutput = true
        case "--list-audio": options.listAudioDevices = true
        case "--restore-output": options.restoreOutput = true
        case "--capture-gain": options.captureGain = Double(next()) ?? options.captureGain
        case "--no-auto-level": options.captureAutoLevel = false
        case "--output-device": options.outputDevice = next()
        case "--capture-dump": options.captureDump = next()
        case "--pcm-stdin": options.pcmStdin = true
        case "--pcm-file": options.pcmFile = next()
        case "--pcm-socket": options.pcmSocket = next()
        case "--pcm-rate": options.pcmRate = Int(next()) ?? options.pcmRate
        case "--pcm-channels": options.pcmChannels = Int(next()) ?? options.pcmChannels
        case "--pcm-volume": options.pcmVolume = Double(next()) ?? options.pcmVolume
        case "--pcm-selftest": options.pcmSelftest = true
        case "--async": options.asyncSend = true
        case "--inflight": options.maxInFlight = Int(next()) ?? options.maxInFlight
        case "--dump": options.dumpPath = next()
        default:
            print("неизвестный аргумент: \(arg)")
            exit(2)
        }
    }
    if options.native {
        // Рабочий профиль DS4: 16 кГц (кадр несёт 8 мс), joint stereo,
        // bitpool 12 (37 B) — это 4.6 КБ/с, ровно потолок канала (~5 КБ/с),
        // то есть 100 % реалтайма. Отчёт 0x18 — самый большой (526 B),
        // в него влезает 13 кадров = 104 мс аудио.
        options.reportID = 0x18
        options.mono = false
        options.dual = false
        options.bitpool = 12
        options.sampleRate = 16_000
        options.audioOffset = 6
    }
    if options.allocation != "snr" && options.allocation != "loudness" {
        print("--allocation: ожидается snr или loudness, получено «\(options.allocation)»")
        exit(2)
    }
    if let lp = options.lowpassHz, lp <= 0 || lp >= Double(options.sampleRate) / 2 {
        print("--lowpass: частота должна быть в диапазоне 1…\(options.sampleRate / 2 - 1) Гц")
        exit(2)
    }
    if let hp = options.highpassHz, hp <= 0 || hp >= Double(options.sampleRate) / 2 {
        print("--highpass: частота должна быть в диапазоне 1…\(options.sampleRate / 2 - 1) Гц")
        exit(2)
    }
    if let hold = options.downsampleHoldHz, hold <= 0 || hold >= Double(options.sampleRate) {
        print("--downsample-hold: частота должна быть в диапазоне 1…\(options.sampleRate - 1) Гц")
        exit(2)
    }
    if let bits = options.bitcrushBits, bits < 4 || bits > 16 {
        print("--bitcrush: допустимо 4…16 бит, получено \(bits)")
        exit(2)
    }
    if options.limitDb > -1.4 {
        print(String(format: "--limit %.2f выше безопасного потолка: использую -1.4 дБFS",
                     options.limitDb))
        options.limitDb = -1.4
    }
    return options
}

func hexDump(_ bytes: [UInt8], limit: Int = 64) -> String {
    let slice = bytes.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
    return bytes.count > limit ? slice + " … (\(bytes.count) B)" : slice
}

/// Счётчики асинхронной отправки: сколько репортов «в полёте» и с какой задержкой
/// приходит подтверждение от HID-стека.
final class AsyncStats {
    private let lock = NSLock()
    private var _inFlight = 0
    private var _completed = 0
    private var _latencies: [Double] = []
    private var _errors = 0

    var inFlight: Int { lock.lock(); defer { lock.unlock() }; return _inFlight }
    var completed: Int { lock.lock(); defer { lock.unlock() }; return _completed }
    var latencies: [Double] { lock.lock(); defer { lock.unlock() }; return _latencies }
    var errors: Int { lock.lock(); defer { lock.unlock() }; return _errors }

    func begin() { lock.lock(); _inFlight += 1; lock.unlock() }
    func end(result: IOReturn, latencyMs: Double) {
        lock.lock()
        _inFlight -= 1
        _completed += 1
        if result == kIOReturnSuccess { _latencies.append(latencyMs) } else { _errors += 1 }
        lock.unlock()
    }
}

/// Живая громкость из файла (для GUI).
///
/// GUI пишет в файл одну строку вида «0x18», зонд раз в 100 мс читает его.
/// Так громкость можно менять во время стрима, не перезапуская процесс:
/// при изменении мы просто переотправляем control-отчёт 0x11.
final class LiveVolumeFile {
    private let path: String
    private let lock = NSLock()
    private var pending: UInt8?
    private var lastSeen: UInt8
    private var stopped = false

    init(path: String, initial: UInt8) {
        self.path = path
        self.lastSeen = initial
    }

    func start() {
        let thread = Thread { [weak self] in
            while true {
                guard let self else { return }
                self.lock.lock()
                let stop = self.stopped
                self.lock.unlock()
                if stop { return }
                if let text = try? String(contentsOfFile: self.path, encoding: .utf8),
                   let value = Self.parse(text) {
                    self.lock.lock()
                    if value != self.lastSeen {
                        self.lastSeen = value
                        self.pending = value
                    }
                    self.lock.unlock()
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        thread.name = "ds4-volume-file"
        thread.start()
    }

    func takePending() -> UInt8? {
        lock.lock(); defer { lock.unlock() }
        let value = pending
        pending = nil
        return value
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private static func parse(_ text: String) -> UInt8? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.lowercased().hasPrefix("0x") {
            return UInt8(cleaned.dropFirst(2), radix: 16)
        }
        if let decimal = UInt8(cleaned) { return decimal }
        return UInt8(cleaned, radix: 16)
    }
}

// MARK: - main

let options = parseOptions()

if options.listOnly {
    Ds4Device.listAllHidDevices()
    exit(0)
}

if let want = options.outputDevice {
    let outputs = AudioDevices.listOutputs()
    guard let match = outputs.first(where: { $0.name.localizedCaseInsensitiveContains(want) }) else {
        print("Устройство вывода «\(want)» не найдено. Доступны: " +
              outputs.map { $0.name }.joined(separator: ", "))
        exit(1)
    }
    if AudioDevices.setDefaultOutput(match.id) {
        print("Вывод системы переключён на «\(match.name)»")
    } else {
        print("Не удалось переключить вывод системы на «\(match.name)»")
        exit(1)
    }
    exit(0)
}

if options.restoreOutput {
    if DefaultOutputState.restore() {
        exit(0)
    } else {
        print("Нечего восстанавливать (файл состояния не найден).")
        exit(1)
    }
}

if options.listAudioDevices {
    print("Аудиоустройства с входом (в них можно писать системный звук):")
    for d in AudioDevices.listInputs() {
        print("  \(d.name) — ID \(d.id), входов: \(d.inputChannels)")
    }
    print("Устройства вывода:")
    for d in AudioDevices.listOutputs() {
        print("  \(d.name) — ID \(d.id), выходов: \(d.inputChannels)")
    }
    if let def = AudioDevices.defaultOutput() {
        print("Вывод по умолчанию сейчас: \(def.name)")
    }
    exit(0)
}

let encoder = SbcFrameEncoder(sampleRate: Int32(options.sampleRate), bitpool: options.bitpool,
                              mono: options.mono, dual: options.dual,
                              allocation: options.allocation == "loudness"
                                ? SBC_AM_LOUDNESS : SBC_AM_SNR)

print("=== ds4probe ===")
print("SBC: \(options.sampleRate / 1000) кГц, 8 подполос, 16 блоков, Joint Stereo, "
      + "\(encoder.allocationName), bitpool \(options.bitpool)")
print("SBC: " + (options.mono ? "MONO" : "Joint Stereo") +
      ", битпул \(options.bitpool) → кадр \(encoder.frameLength) байт, вход \(encoder.codeSize) байт")

if options.selftest {
    // Проверка байтовой раскладки кадра на эталонном кодеке.
    var tone = ToneGenerator(frequency: options.frequency, sampleRate: Double(options.sampleRate), amplitude: options.toneAmp,
                         rightFrequency: options.frequencyR > 0 ? options.frequencyR : options.frequency,
                         rightAmplitude: options.muteRight ? 0.0 : options.toneAmp)
    let (left, right) = tone.nextFrame()
    let frame = encoder.encode(left: left, right: right)
    print("Кадр (первые 16 B): \(hexDump(frame, limit: 16))")
    print("  syncword=0x\(String(format: "%02X", frame[0])) " +
          "config=0x\(String(format: "%02X", frame[1])) " +
          "bitpool=0x\(String(format: "%02X", frame[2])) " +
          "crc8=0x\(String(format: "%02X", frame[3]))")
    exit(0)
}

// Число кадров в репорте: либо задано явно, либо максимум, влезающий
// в отчёт между смещением аудио и хвостовым CRC.
let reportTotal = Ds4Report.totalLength(reportID: options.reportID)
let framesPerReport: Int = options.framesPerReportOverride > 0
    ? options.framesPerReportOverride
    : max(1, (reportTotal - options.audioOffset - 4) / encoder.frameLength)
print("Репорт: 0x\(String(format: "%02X", options.reportID)) (\(framesPerReport) кадров, " +
      "длина \(Ds4Report.totalLength(reportID: options.reportID)))")
print("Цель: \(options.target == 0x02 ? "встроенный динамик" : "3.5 мм джек"), " +
      "mode=0x\(String(format: "%02X", options.modeByte)), " +
      "handshake=0x\(String(format: "%02X", options.handshake)), " +
      "громкость=\(options.volume) (\(Int(options.volume) * 100 / 79) %)")

if options.dry {
    var tone = ToneGenerator(frequency: options.frequency, sampleRate: Double(options.sampleRate), amplitude: options.toneAmp,
                         rightFrequency: options.frequencyR > 0 ? options.frequencyR : options.frequency,
                         rightAmplitude: options.muteRight ? 0.0 : options.toneAmp)
    var frames: [[UInt8]] = []
    for _ in 0 ..< framesPerReport {
        let (left, right) = tone.nextFrame()
        frames.append(encoder.encode(left: left, right: right))
    }
    let control = Ds4Report.control(target: options.target, volume: options.volume,
                                    modeByte: options.modeByte, handshake: options.handshake,
                                    lightbar: options.lightbar, pollRate: options.pollRate)
    let stream = Ds4Report.stream(reportID: options.reportID, frameNumber: 0, frames: frames,
                                   target: options.target, modeByte: options.modeByte,
                                   audioOffset: options.audioOffset, pollRate: options.pollRate)
    print("\n--- Report 0x11 (\(control.count) B) ---")
    print(hexDump(control, limit: 78))
    print("--- Report 0x\(String(format: "%02X", options.reportID)) (\(stream.count) B) ---")
    print(hexDump(stream, limit: 48))
    // Самопроверка CRC
    let crcStored = Array(stream.suffix(4)).withUnsafeBytes { raw in
        raw.load(as: UInt32.self).littleEndian
    }
    let crcComputed = Ds4Crc32.compute(Array(stream[0 ..< stream.count - 4]), prefix: 0xA2)
    print("\nCRC в хвосте: 0x\(String(format: "%08X", crcStored)) — вычислено: 0x\(String(format: "%08X", crcComputed)) — " +
          (crcStored == crcComputed ? "СОВПАДАЕТ" : "НЕ СОВПАДАЕТ"))
    if let path = options.dumpPath {
        let text = ([control, stream].map { hexDump($0, limit: $0.count) }).joined(separator: "\n\n")
        try! text.write(toFile: path, atomically: true, encoding: .utf8)
        print("Дамп записан в \(path)")
    }
    exit(0)
}

if options.pcmSelftest {
    // Проверка тракта без контроллера: длительность должна сохраниться,
    // пик — не вырасти выше исходного.
    let reader: FileHandle
    if let path = options.pcmFile {
        guard let fh = FileHandle(forReadingAtPath: path) else {
            print("Не удалось открыть PCM-файл: \(path)")
            exit(1)
        }
        reader = fh
    } else {
        reader = FileHandle.standardInput
    }
    do {
        let result = try PcmStreamSource.selftest(inputRate: options.pcmRate,
                                                  channels: options.pcmChannels,
                                                  reader: reader,
                                                  outputRate: options.sampleRate)
        let inputDuration = Double(result.inputFrames) / Double(options.pcmRate)
        let peakDb = result.peak > 0 ? 20 * log10(Double(result.peak) / 32768.0) : -99
        print("PCM selftest: вход \(result.inputFrames) кадров @\(options.pcmRate) Гц "
              + "(\(String(format: "%.3f", inputDuration)) с), "
              + "выход \(result.outputFrames) кадров @\(options.sampleRate) Гц "
              + "(\(String(format: "%.3f", result.duration)) с), "
              + "пик \(String(format: "%.1f", peakDb)) дБFS")
        exit(0)
    } catch {
        print("PCM selftest: ошибка — \(error)")
        exit(1)
    }
}

if options.processOnly {
    guard let path = options.playPath else {
        print("--process-only требует --play <файл>")
        exit(2)
    }
    do {
        let prepared = try preparePlayback(path: path, options: options,
                                           saveProcessed: options.saveProcessed)
        print("Готово без отправки в DS4: \(prepared.frames.count) кадров @\(options.sampleRate) Гц")
        exit(0)
    } catch {
        print("Ошибка DSP: \(error)")
        exit(1)
    }
}

// Живое устройство
let device: Ds4Device
do {
    device = try Ds4Device(vendorID: options.vendorID, productID: options.productID,
                           requireBluetooth: options.requireBluetooth,
                           transportFilter: options.transport,
                           waitSeconds: options.waitSeconds,
                           registerInput: !options.noInput)
} catch {
    print("Ошибка: \(error)")
    exit(1)
}
print("Устройство: \(device.product)")

// Живая громкость для GUI: файл опрашивается в фоне, поток не прерывается.
let liveVolume: LiveVolumeFile?
if let path = options.volumeFile {
    let watcher = LiveVolumeFile(path: path, initial: options.volume)
    watcher.start()
    liveVolume = watcher
    print("Живая громкость: \(path)")
} else {
    liveVolume = nil
}

let control = Ds4Report.control(target: options.target, volume: options.volume,
                                modeByte: options.modeByte, handshake: options.handshake,
                                lightbar: options.lightbar, pollRate: options.pollRate)
if options.inputOnly {
    // Только приём: считаем входящие input-репорты, ничего не отправляя.
    print("Режим --input-only: считаю входящие репорты 5 с…")
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    let rate = device.inputRate()
    print("Входящие input-репорты: \(rate.count) шт., темп \(String(format: "%.1f", rate.perSecond)) шт/с")
    for (id, bytes) in device.snapshotInputReports().sorted(by: { $0.key < $1.key }) {
        print("  ID 0x\(String(format: "%02X", id)): \(bytes.count) B — \(hexDump(bytes, limit: 24))")
    }
    exit(0)
}

// Разрешаем приём input-репортов: запускаем run loop на фоне.
// Важно: run loop поднимается ДО отправки 0x11 — иначе мы не увидим реакцию
// контроллера (после взвода он отвечает входящим репортом 0x11).
let runLoopThread = Thread {
    CFRunLoopRun()
}
runLoopThread.start()
Thread.sleep(forTimeInterval: 0.2)

// Слежение за изменениями входящего репорта — печатаем каждый дифф целиком.
let watchStarted = Date()
if let watchID = options.watchInputID {
    print("Слежу за входящим репортом ID 0x\(String(format: "%02X", watchID))…")
    let watcher = Thread {
        var printed = 0
        while true {
            let h = device.history(for: watchID)
            if h.count > printed {
                for i in printed ..< h.count {
                    let ts = Date().timeIntervalSince(watchStarted)
                    print(String(format: "[watch %6.3f c] ID 0x%02X (%d B): ", ts, watchID, h[i].count)
                          + hexDump(h[i], limit: 96))
                }
                printed = h.count
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
    watcher.start()
}

if !options.noArm {
    print("Отправляю Report 0x11 («взвод» аудиоплоскости)… RGB=\(options.lightbar.0),\(options.lightbar.1),\(options.lightbar.2)")
    do {
        for attempt in 1 ... options.armRepeat {
            try device.send(control, stripID: options.stripID)
            print("  отправлен #\(attempt), \(control.count) B")
            if attempt < options.armRepeat { Thread.sleep(forTimeInterval: 0.2) }
        }
    } catch {
        print("  ошибка: \(error)")
        exit(1)
    }
} else {
    print("Режим --no-arm: ничего не отправляю, только наблюдаю.")
}

if options.armOnly {
    print("Режим --arm-only: жду \(options.seconds) с…")
    // Крутим ГЛАВНЫЙ run loop: IOHIDManager подписан именно на него,
    // поэтому обычный sleep здесь глушил бы входящие репорты.
    let watchDeadline = Date().addingTimeInterval(options.seconds)
    while Date() < watchDeadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    let rate = device.inputRate()
    print("Входящие input-репорты: \(rate.count) шт., темп \(String(format: "%.1f", rate.perSecond)) шт/с")
    for (id, bytes) in device.snapshotInputReports().sorted(by: { $0.key < $1.key }) {
        print("  ID 0x\(String(format: "%02X", id)): \(bytes.count) B — \(hexDump(bytes, limit: 96))")
    }
    exit(0)
}

// MARK: - Захват системного аудио
//
// Системный звук пишется в виртуальное loopback-устройство «DualShock 4»
// (HAL-драйвер из tools/ds4driver), мы читаем его вход и отправляем в
// динамик DS4 — так контроллер работает как аудиоустройство.
var systemCapture: SystemAudioCapture? = nil
var systemCaptureDevice: AudioInputDeviceInfo? = nil
if options.systemAudio {
    let inputs = AudioDevices.listInputs()
    guard !inputs.isEmpty else {
        print("Нет аудиоустройств с входом. Установите драйвер: sudo tools/ds4driver/install-driver.sh")
        exit(1)
    }
    let chosen: AudioInputDeviceInfo
    if let want = options.captureDevice {
        guard let match = inputs.first(where: {
            $0.name.localizedCaseInsensitiveContains(want)
        }) else {
            print("Устройство «\(want)» не найдено. Доступны: " +
                  inputs.map { $0.name }.joined(separator: ", "))
            exit(1)
        }
        chosen = match
    } else if let ds4 = inputs.first(where: {
        $0.name.localizedCaseInsensitiveContains("DualShock 4")
    }) {
        chosen = ds4
    } else if let bh = inputs.first(where: {
        $0.name.localizedCaseInsensitiveContains("blackhole")
    }) {
        chosen = bh
    } else {
        chosen = inputs[0]
    }
    print("Захват системного аудио: «\(chosen.name)» (входов: \(chosen.inputChannels))")
    let stamp = DateFormatter()
    stamp.dateFormat = "HH:mm:ss.SSS"
    stamp.locale = Locale(identifier: "en_US_POSIX")
    print("Захват начат в \(stamp.string(from: Date()))")
    // Сначала переключаем вывод системы: смена устройства вывода пересоздаёт
    // входной audio unit, и tap, поднятый до переключения, молча умирает.
    if options.setDefaultOutput {
        if let previous = AudioDevices.defaultOutput() {
            DefaultOutputState.remember(previous.id)
            print("Прежний вывод системы: «\(previous.name)» (вернуть: --restore-output)")
        }
        if let old = AudioDevices.outputVolume(chosen.id), old < 0.99 {
            AudioDevices.setOutputVolume(chosen.id, 1.0)
            print("Громкость устройства «\(chosen.name)» поднята с " +
                  "\(String(format: "%.0f", old * 100)) % до 100 %")
        }
        if AudioDevices.setDefaultOutput(chosen.id) {
            print("Вывод системы переключён на «\(chosen.name)». " +
                  "Вернуть: панель «Звук» → «Вывод устройства» или --restore-output.")
        } else {
            print("Не удалось переключить вывод системы на «\(chosen.name)»")
        }
        // Ctrl-C / SIGTERM возвращают вывод системы, чтобы у пользователя
        // не пропало системное звучание.
        SignalRestore().install(restore: {
            _ = DefaultOutputState.restore()
        })
    }
    do {
        let capture = try SystemAudioCapture(device: chosen, targetRate: options.sampleRate)
        capture.gain = options.captureGain
        capture.autoLevel = options.captureAutoLevel
        capture.dumpPath = options.captureDump
        try capture.start()
        systemCapture = capture
        systemCaptureDevice = chosen
    } catch {
        print("Не удалось запустить захват: \(error)")
        exit(1)
    }
}

// MARK: - Потоковый PCM-вход
//
// Сырые s16le сэмплы (моно или стерео) → ресемплинг в 16 кГц → SBC.
// Так Dolphin может отдавать сюда уже декодированный звук динамика Wiimote.
var pcmSource: PcmStreamSource? = nil
if options.pcmStdin || options.pcmFile != nil || options.pcmSocket != nil {
    let source: PcmStreamSource
    if let path = options.pcmSocket {
        do {
            source = try PcmStreamSource(inputRate: options.pcmRate, channels: options.pcmChannels,
                                         socketPath: path, outputRate: options.sampleRate,
                                         volume: options.pcmVolume)
        } catch {
            print("Не удалось открыть PCM-сокет: \(error)")
            exit(1)
        }
        print("PCM-сокет: \(path) (\(options.pcmRate) Гц, каналов \(options.pcmChannels))")
    } else {
        let reader: FileHandle
        if let path = options.pcmFile {
        guard let fh = FileHandle(forReadingAtPath: path) else {
            print("Не удалось открыть PCM-файл: \(path)")
            exit(1)
        }
        reader = fh
        } else {
            reader = FileHandle.standardInput
        }
        source = PcmStreamSource(inputRate: options.pcmRate, channels: options.pcmChannels,
                                 reader: reader, outputRate: options.sampleRate,
                                 volume: options.pcmVolume)
        print("PCM-вход: \(options.pcmRate) Гц, каналов \(options.pcmChannels) → "
              + "\(options.sampleRate) Гц → DS4")
    }
    source.start()
    pcmSource = source
}

// Поток стриминга
let streamThread = Thread {
    var tone = ToneGenerator(frequency: options.frequency, sampleRate: Double(options.sampleRate), amplitude: options.toneAmp,
                         rightFrequency: options.frequencyR > 0 ? options.frequencyR : options.frequency,
                         rightAmplitude: options.muteRight ? 0.0 : options.toneAmp)
    var frameNumber: UInt16 = 0
    // --seconds — длительность СТЕАМИНГА по стенным часам. Раньше здесь считалось
    // число отчётов из «секунд аудио», из-за чего 4 с аудио растягивались на
    // 22 с реального времени (запись блокируется ~90 мс) и процесс упирался
    // в timeout, теряя весь вывод.
    // Время старта выставляем позже — после загрузки файла и взвода
    // аудиоплоскости. Иначе --seconds отсчитывался бы от запуска потока,
    // а первые отчёты всё равно уходят через 250+ мс, и «реалтайм»
    // показывал бы 97 %.
    var start = Date()
    // Для потокового PCM работаем до EOF, если `--seconds` не задан явно.
    // Это важно для helper-процесса из Dolphin: он живёт всё время игры.
    let untilEOF = pcmSource != nil && !options.secondsSpecified
    var deadline = untilEOF ? Date.distantFuture : start.addingTimeInterval(options.seconds)
    var sent = 0
    var errors = 0
    var sendTimes: [Double] = []
    var sendIntervals: [Double] = []
    var lastSend = start
    var lastInputTotal = device.inputTotal()
    var lastInputSample = start
    var minInputRate = 1e9
    var maxInputRate = 0.0
    let stats = AsyncStats()
    var nextTick = start

    // Источник кадров: WAV-файл (--play) либо бесконечный тон.
    var wavFrames: [(left: [Int16], right: [Int16])] = []
    var wavIndex = 0
    // Тон, PCM и системный звук обрабатываются потоково.
    let streamingDsp: StreamingDspProcessor? = options.playPath == nil
        ? StreamingDspProcessor(config: makeDspConfig(options))
        : nil
    if let streamingDsp {
        print("DSP (поток): \(dspDescription(makeDspConfig(options)))")
        print("  пики будут выведены по завершении потока")
        _ = streamingDsp
    }
    // Для --play обработка выполняется целым файлом (глобальная нормализация,
    // стабильные бикуады). Потоковый DSP нужен для тона/PCM/системного звука.
    if let path = options.playPath {
        do {
            let prepared = try preparePlayback(path: path, options: options,
                                               saveProcessed: options.saveProcessed)
            wavFrames = prepared.frames
            print("WAV: \(path) — \(wavFrames.count) кадров по \(options.sampleRate) Гц "
                  + "(\(String(format: "%.2f", Double(wavFrames.count) * 128.0 / Double(options.sampleRate))) с)")
            if wavFrames.isEmpty { exit(1) }
        } catch {
            print("Ошибка чтения WAV: \(error)")
            exit(1)
        }
    }

    // Даём аудиоплоскости DS4 подняться: первые отчёты после взвода могут
    // уйти в никуда, и начало файла теряется.
    if options.armDelayMs > 0 {
        Thread.sleep(forTimeInterval: options.armDelayMs / 1000.0)
    }

    /// Следующий кадр 128 сэмплов из выбранного источника (PCM, системный
    /// захват, WAV или тон) с уже применённым потоковым DSP.
    func nextAudioFrame(useSource: Bool = true) -> (left: [Int16], right: [Int16]) {
        var left: [Int16]
        var right: [Int16]
        if !useSource {
            left = [Int16](repeating: 0, count: 128)
            right = [Int16](repeating: 0, count: 128)
            return (left, right)
        }
        if let source = pcmSource {
            // PCM-поток из Dolphin: при недоборе — тишина, чтобы DSP
            // контроллера не сбрасывался.
            (left, right) = source.nextFrame()
        } else if let capture = systemCapture {
            // Системное аудио: при недоборе подставляется тишина,
            // чтобы DSP контроллера не сбрасывался.
            (left, right) = capture.nextFrame()
        } else if wavFrames.isEmpty {
            (left, right) = tone.nextFrame()
        } else {
            if wavIndex >= wavFrames.count && !options.loop {
                // Файл закончился — шлём тишину и не зацикливаем
                // (переход конец→начало слышен как щелчок).
                left = [Int16](repeating: 0, count: 128)
                right = [Int16](repeating: 0, count: 128)
            } else {
                let f = wavFrames[wavIndex % wavFrames.count]
                wavIndex += 1
                left = f.left
                right = f.right
            }
        }
        if let streamingDsp {
            streamingDsp.process(left: &left, right: &right)
        }
        return (left, right)
    }

    let reportsPerTick = max(1, options.burst)
    var reportsInTick = 0
    var volumeChanged = false
    var currentVolume = options.volume
    // КРИТИЧНО: nextTick отсчитывался от старта потока, а до цикла мы
    // грузили файл и ждали взвод (--arm-delay). К моменту первого отчёта
    // nextTick уже в прошлом, и планировщик «догонял» его пачкой: 3–4
    // отчёта (320 мс звука) за 1–2 мс, затем провал. На слух это и было
    // заикание в начале. Начинаем отсчёт темпа здесь.
    start = Date()
    nextTick = start
    lastSend = start
    lastInputSample = start
    var lastCaptureRebuild = Date.distantPast
    if !untilEOF {
        deadline = start.addingTimeInterval(options.seconds)
    }
    while Date() < deadline {
        if untilEOF, let source = pcmSource, source.finished {
            break
        }
        // Смена системного вывода пересоздаёт входной audio unit, и tap
        // захвата при этом молча умирает: колбэки перестают приходить, а мы
        // продолжаем слать в контроллер тишину — звука нет, а «поток активен».
        // Ловим остановку колбэков и поднимаем tap заново.
        if let capture = systemCapture, let device = systemCaptureDevice,
           !capture.isTapAlive,
           Date().timeIntervalSince(lastCaptureRebuild) > 3 {
            lastCaptureRebuild = Date()
            print("[capture] tap перестал приходить (смена вывода?) — пересоздаём…")
            do {
                try capture.rebuild(device: device)
                print("[capture] tap пересоздан, захват восстановлен")
            } catch {
                print("[capture] не удалось пересоздать tap: \(error)")
            }
        }
        // Живая громкость из GUI: файл, который пишет приложение.
        // Громкость живёт в control-отчёте 0x11, поэтому переотправляем его,
        // не прерывая аудиопоток.
        if let watcher = liveVolume, let newVolume = watcher.takePending(),
           newVolume != currentVolume {
            currentVolume = newVolume
            let newControl = Ds4Report.control(target: options.target,
                                               volume: newVolume,
                                               modeByte: options.modeByte,
                                               handshake: options.handshake,
                                               lightbar: options.lightbar,
                                               pollRate: options.pollRate)
            do {
                try device.send(newControl, stripID: options.stripID)
                print("[volume] громкость → 0x\(String(format: "%02X", newVolume)) "
                      + "(\((Int(newVolume) * 100) / 79) % от максимума), "
                      + "t=\(String(format: "%.1f", Date().timeIntervalSince(start))) с")
            } catch {
                print("[volume] ошибка смены громкости: \(error)")
            }
        }
        // Смена громкости по ходу: переотправляем control-отчёт 0x11.
        if !volumeChanged && options.volumeChangeAt >= 0,
           Date().timeIntervalSince(start) >= options.volumeChangeAt {
            volumeChanged = true
            currentVolume = options.volumeChangeTo
            let newControl = Ds4Report.control(target: options.target,
                                               volume: options.volumeChangeTo,
                                               modeByte: options.modeByte,
                                               handshake: options.handshake,
                                               lightbar: options.lightbar,
                                               pollRate: options.pollRate)
            do {
                try device.send(newControl, stripID: options.stripID)
                print("[volume] громкость → 0x\(String(format: "%02X", options.volumeChangeTo)) "
                      + "(\((Int(options.volumeChangeTo) * 100) / 79) % от максимума), "
                      + "t=\(String(format: "%.1f", Date().timeIntervalSince(start))) с")
            } catch {
                print("[volume] ошибка смены громкости: \(error)")
            }
        }
        var frames: [[UInt8]] = []
        for _ in 0 ..< framesPerReport {
            let f = nextAudioFrame()
            frames.append(encoder.encode(left: f.left, right: f.right))
        }
        let report = Ds4Report.stream(reportID: options.reportID, frameNumber: frameNumber,
                                      frames: frames, target: options.target,
                                      modeByte: options.modeByte, audioOffset: options.audioOffset,
                                      pollRate: options.pollRate)
        if options.asyncSend {
            // Асинхронная отправка: держим не больше maxInFlight репортов в полёте.
            while stats.inFlight >= options.maxInFlight {
                Thread.sleep(forTimeInterval: 0.002)
            }
            stats.begin()
            device.sendAsync(report, stripID: options.stripID) { result, latencyMs in
                stats.end(result: result, latencyMs: latencyMs)
            }
            sent += 1
        } else {
            do {
                let t0 = Date()
                // Интервал между отправками: если он заметно больше планового,
                // значит канал (или BT-ссылка) встал — это и есть «прерывание».
                let sinceLast = t0.timeIntervalSince(lastSend) * 1000
                if sent > 0 {
                    sendIntervals.append(sinceLast)
                    // Стартовая диагностика: первые отчёты показывают, не
                    // «просыпается» ли линк и не теряется ли начало.
                    if sent <= 5 {
                        print(String(format: "[startup] отчёт %d: интервал %.1f мс", sent + 1, sinceLast))
                    }
                    // Номинал: framesPerReport × длительность кадра. Превышение
                    // на 40 % — реальный провал доставки (слышно как щелчок).
                    let nominal = frameDurationMs(sampleRate: options.sampleRate) * Double(framesPerReport)
                    if sinceLast > nominal * 1.4 {
                        print(String(format: "[stall] пауза %.0f мс перед отчётом %d (номинал %.0f мс)",
                                     sinceLast, sent, nominal))
                    }
                }
                lastSend = t0
                try device.send(report, stripID: options.stripID)
                let dt = Date().timeIntervalSince(t0) * 1000
                sendTimes.append(dt)
                if sent <= 5 {
                    print(String(format: "[startup] отчёт %d: запись %.1f мс", sent + 1, dt))
                }
                sent += 1
                if sent % 25 == 0 {
                    print(String(format: "[stream] отчёт %d, t=%.1f с, последняя запись %.1f мс",
                                 sent, Date().timeIntervalSince(start), dt))
                }
                // Диагностика задержки в системном режиме: сколько аудио
                // лежит в буфере захвата (это наша собственная задержка).
                if let capture = systemCapture, sent % 50 == 0 {
                    let buffered = capture.bufferedSeconds
                    let consumed = Double(sent * framesPerReport) * frameDurationMs(sampleRate: options.sampleRate) / 1000.0
                    print(String(format: "[latency] буфер захвата %.3f с | принято %.2f с, отправлено %.2f с, дрейф %+.3f с | tap %@",
                                 buffered, Double(capture.capturedFrames) / Double(options.sampleRate),
                                 consumed, Double(capture.capturedFrames) / Double(options.sampleRate) - consumed,
                                 capture.isTapAlive ? "жив" : "МЁРТВ"))
                }
                if let source = pcmSource, sent % 50 == 0 {
                    let consumed = Double(sent * framesPerReport)
                        * frameDurationMs(sampleRate: options.sampleRate) / 1000.0
                    print(String(format: "[pcm] буфер %.3f с, underrun %d, overrun %d, "
                                         + "вход %.2f с, выдано %.2f с",
                                 source.bufferedSeconds, source.underruns, source.overrunCount,
                                 source.inputSeconds, consumed))
                }
            } catch {
                errors += 1
                if errors == 1 { print("  ошибка отправки: \(error)") }
            }
        }
        frameNumber &+= UInt16(framesPerReport)

        // Окночная оценка темпа входящих репортов: падение темпа = потеря
        // BT-ссылки (входящий канал идёт независимо от исходящего).
        let now = Date()
        if now.timeIntervalSince(lastInputSample) >= 0.2 {
            let total = device.inputTotal()
            let delta = total - lastInputTotal
            let dt = now.timeIntervalSince(lastInputSample)
            let rate = Double(delta) / dt
            if rate < minInputRate { minInputRate = rate }
            if rate > maxInputRate { maxInputRate = rate }
            if rate < 15 {
                print(String(format: "[link] входящих репортов всего %.0f/с — BT-ссылка просела", rate))
            }
            lastInputTotal = total
            lastInputSample = now
        }

        // Точное планирование: отправка пачками по reportsPerTick отчётов,
        // затем пауза до следующего тика (раз в тик — reportsPerTick × 4 мс аудио).
        reportsInTick += 1
        if reportsInTick >= reportsPerTick {
            reportsInTick = 0
            if options.unpaced {
                // Без пауз: копим отчёты максимально быстро — если системный
                // BT-стек отдаёт их пачками, буфер DS4 наполнится целиком.
                nextTick = Date()
                continue
            }
            let pace = options.paceMs > 0 ? options.paceMs : frameDurationMs(sampleRate: options.sampleRate) * Double(framesPerReport * reportsPerTick)
            nextTick = nextTick.addingTimeInterval(pace / 1000.0)
            let sleep = nextTick.timeIntervalSinceNow
            if sleep > 0 { Thread.sleep(forTimeInterval: sleep) }
        }
    }

    let elapsed = Date().timeIntervalSince(start)
    let audioSeconds = Double(sent * framesPerReport) * frameDurationMs(sampleRate: options.sampleRate) / 1000.0
    print("\nОтправлено репортов: \(sent), ошибок: \(errors), " +
          "темп: \(String(format: "%.1f", Double(sent) / elapsed)) реп/с")
    print("Подано аудио: \(String(format: "%.2f", audioSeconds)) с за \(String(format: "%.2f", elapsed)) с " +
          "— \(String(format: "%.0f", audioSeconds / elapsed * 100)) % реалтайма")
    if !sendTimes.isEmpty {
        let sorted = sendTimes.sorted()
        let avg = sendTimes.reduce(0, +) / Double(sendTimes.count)
        print("Время IOHIDDeviceSetReport: avg \(String(format: "%.1f", avg)) мс, " +
              "min \(String(format: "%.1f", sorted.first ?? 0)) мс, " +
              "p50 \(String(format: "%.1f", sorted[sorted.count / 2])) мс, " +
              "max \(String(format: "%.1f", sorted.last ?? 0)) мс")
        let over = sendTimes.filter { $0 > 20 }.count
        print("  репортов с отправкой дольше 20 мс: \(over) из \(sendTimes.count)")
    }
    if options.asyncSend {
        let lat = stats.latencies.sorted()
        let avg = lat.isEmpty ? 0 : lat.reduce(0, +) / Double(lat.count)
        print("Асинхронная отправка: завершено \(stats.completed), ошибок \(stats.errors), " +
              "задержка подтверждения avg \(String(format: "%.1f", avg)) мс, " +
              "p50 \(String(format: "%.1f", lat.isEmpty ? 0 : lat[lat.count / 2])) мс, " +
              "max \(String(format: "%.1f", lat.last ?? 0)) мс")
    }
    if let source = pcmSource {
        print("PCM-вход: прочитано \(source.inputFrames) входных кадров, "
              + "выдано \(source.outputFrames) кадров @\(source.outputRate) Гц, "
              + "длительность входа: \(String(format: "%.2f", source.inputSeconds)) с, "
              + "underrun: \(source.underruns), overrun: \(source.overrunCount), "
              + "буфер: \(String(format: "%.2f", source.bufferedSeconds)) с, "
              + "пик сигнала: \(String(format: "%.1f", 20 * log10(Double(source.peakLevel) / 32768.0))) дБFS")
        if let error = source.errorDescription {
            print("PCM-вход: ошибка чтения — \(error)")
        }
    }
    if let capture = systemCapture {
        capture.writeDump()
        print("Захват «\(capture.deviceName)»: кадров получено \(capture.capturedFrames), " +
              "недоборов (тишина вместо данных): \(capture.underruns), " +
              "буфер: \(String(format: "%.2f", capture.bufferedSeconds)) с, " +
              "пик сигнала: \(String(format: "%.1f", 20 * log10(Double(capture.peakLevel) / 32768.0))) дБFS")
    }
    if let dsp = streamingDsp {
        let p = dsp.stagePeaks
        print("DSP-пики по всему потоку (сумма L+R — то, что складывает динамик):")
        print("  вход:         \(peakLog("канал", p.inputChannel)), \(peakLog("L+R", p.inputSum))")
        print("  фильтры:      \(peakLog("канал", p.afterFiltersChannel)), \(peakLog("L+R", p.afterFiltersSum))")
        if options.compressGain > 1 {
            print("  компрессия:   \(peakLog("канал", p.afterCompressionChannel)), \(peakLog("L+R", p.afterCompressionSum))")
        }
        print("  нормализация: \(peakLog("канал", p.afterNormalizationChannel)), \(peakLog("L+R", p.afterNormalizationSum))")
        print("  лимитер:      \(peakLog("канал", p.afterLimiterChannel)), \(peakLog("L+R", p.afterLimiterSum))")
        print("  выход:        \(peakLog("канал", p.outputChannel)), \(peakLog("L+R", p.outputSum)), "
              + "обработано \(dsp.processedFrames) сэмплов")
    }
    let rate = device.inputRate()
    print("Входящие input-репорты: \(rate.count) шт., темп \(String(format: "%.1f", rate.perSecond)) шт/с")
    if minInputRate < 1e9 {
        print(String(format: "Окно входящего потока: минимум %.0f/с, максимум %.0f/с", minInputRate, maxInputRate))
    }
    let longWrites = sendTimes.filter { $0 > 250 }.count
    print("Задержек записи больше 250 мс: \(longWrites) из \(sendTimes.count)")
    if !sendIntervals.isEmpty {
        let sorted = sendIntervals.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let nominal = frameDurationMs(sampleRate: options.sampleRate) * Double(framesPerReport)
        let over = sendIntervals.filter { $0 > nominal * 1.4 }.count
        print(String(format: "Интервал доставки: номинал %.0f мс, p50 %.0f, p95 %.0f, max %.0f; "
                           + "провалов >140 %% номинала: %d из %d",
                     nominal, p50, p95, sorted.last ?? 0, over, sorted.count))
    }
    let inputs = device.snapshotInputReports()
    if inputs.isEmpty {
        print("Input-репорты от DS4: не получены")
    } else {
        print("Input-репорты от DS4:")
        for (id, bytes) in inputs.sorted(by: { $0.key < $1.key }) {
            print("  ID 0x\(String(format: "%02X", id)): \(bytes.count) B — \(hexDump(bytes, limit: 24))")
        }
    }
    exit(0)
}
streamThread.start()

// Ждём завершения стрима.
while !Thread.current.isFinished {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
}
