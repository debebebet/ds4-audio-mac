import Foundation

// MARK: - DSP перед SBC
//
// Вся обработка работает в float/double и заканчивается только перед
// передачей кадров в SBC-кодер. Пик контролируется по СУММЕ L+R: встроенный
// динамик DS4 моно и складывает каналы. Поэтому нормировка/лимитер считают
// именно |L+R|, а не независимые пики каналов.

func dbfs(_ linear: Double) -> Double {
    linear > 0 ? 20.0 * log10(linear) : -Double.infinity
}

struct DspConfig {
    var sampleRate = 16_000
    var lowpassHz: Double?
    var highpassHz: Double?
    var midBoostDb: Double = 0
    var monoPre = true
    var compressMaxGain: Double = 0
    var normalize = true
    var normalizeByChannelPeak = false
    /// Цель нормализации по сумме L+R (0.999 ≈ −0.01 dBFS).
    var normalizeTarget = 0.999
    /// Лимитер включён всегда: это страховка перед SBC/декодером DS4.
    var limiterCeilingDb = -1.4
    var extraGain: Double = 1
    var downsampleHoldHz: Double?
    var bitcrushBits: Int?

    var limiterCeiling: Double {
        pow(10.0, limiterCeilingDb / 20.0)
    }

    var hasFilters: Bool {
        lowpassHz != nil || highpassHz != nil || abs(midBoostDb) > 0.001
    }
}

struct DspStagePeaks {
    var inputChannel: Double = 0
    var inputSum: Double = 0
    var afterFiltersChannel: Double = 0
    var afterFiltersSum: Double = 0
    var afterCompressionChannel: Double = 0
    var afterCompressionSum: Double = 0
    var afterNormalizationChannel: Double = 0
    var afterNormalizationSum: Double = 0
    var afterLimiterChannel: Double = 0
    var afterLimiterSum: Double = 0
    var outputChannel: Double = 0
    var outputSum: Double = 0
}

struct DspProcessResult {
    var left: [Int16]
    var right: [Int16]
    var peaks: DspStagePeaks
    var normalizationGain: Double = 1
    var midBoostSafetyGain: Double = 1
    /// true, если какой-либо этап (фильтры/повышение/лимитер) упирался в
    /// полную шкалу и потребовал защитного уменьшения.
    var clippedBeforeOutput = false
}

// MARK: - Бикуады

struct BiquadCoefficients {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

    static func lowpass(frequency: Double, sampleRate: Double, q: Double) -> BiquadCoefficients {
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2.0 * q)
        let cosw = cos(w0)
        let a0 = 1.0 + alpha
        return BiquadCoefficients(
            b0: ((1.0 - cosw) * 0.5) / a0,
            b1: (1.0 - cosw) / a0,
            b2: ((1.0 - cosw) * 0.5) / a0,
            a1: (-2.0 * cosw) / a0,
            a2: (1.0 - alpha) / a0)
    }

    static func highpass(frequency: Double, sampleRate: Double, q: Double) -> BiquadCoefficients {
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2.0 * q)
        let cosw = cos(w0)
        let a0 = 1.0 + alpha
        return BiquadCoefficients(
            b0: ((1.0 + cosw) * 0.5) / a0,
            b1: (-(1.0 + cosw)) / a0,
            b2: ((1.0 + cosw) * 0.5) / a0,
            a1: (-2.0 * cosw) / a0,
            a2: (1.0 - alpha) / a0)
    }

    static func peaking(frequency: Double, sampleRate: Double, q: Double,
                        gainDb: Double) -> BiquadCoefficients {
        let a = pow(10.0, gainDb / 40.0)
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2.0 * q)
        let cosw = cos(w0)
        let a0 = 1.0 + alpha / a
        return BiquadCoefficients(
            b0: (1.0 + alpha * a) / a0,
            b1: (-2.0 * cosw) / a0,
            b2: (1.0 - alpha * a) / a0,
            a1: (-2.0 * cosw) / a0,
            a2: (1.0 - alpha / a) / a0)
    }
}

struct BiquadState {
    var z1 = 0.0
    var z2 = 0.0

    mutating func process(_ x: Double, _ c: BiquadCoefficients) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}

/// Каскад бикуадов, отдельное состояние для L и R.
final class StereoFilterBank {
    private struct Stage {
        let coefficients: BiquadCoefficients
        var left = BiquadState()
        var right = BiquadState()
    }

    private var stages: [Stage] = []

    init(highpassHz: Double?, lowpassHz: Double?, midBoostDb: Double,
         sampleRate: Double) {
        if let hp = highpassHz {
            // Баттерворт 2-го порядка.
            stages.append(Stage(coefficients: .highpass(
                frequency: hp, sampleRate: sampleRate, q: 1.0 / sqrt(2.0))))
        }
        if let lp = lowpassHz {
            // Баттерворт 4-го порядка: два бикуада с полюсными Q.
            stages.append(Stage(coefficients: .lowpass(
                frequency: lp, sampleRate: sampleRate, q: 0.541196100146197)))
            stages.append(Stage(coefficients: .lowpass(
                frequency: lp, sampleRate: sampleRate, q: 1.306562964876377)))
        }
        if abs(midBoostDb) > 0.001 {
            stages.append(Stage(coefficients: .peaking(
                frequency: 2_000.0, sampleRate: sampleRate, q: 0.8,
                gainDb: midBoostDb)))
        }
    }

    var isEmpty: Bool { stages.isEmpty }

    func process(left: inout Double, right: inout Double) {
        for i in stages.indices {
            left = stages[i].left.process(left, stages[i].coefficients)
            right = stages[i].right.process(right, stages[i].coefficients)
        }
    }
}

// MARK: - Компрессор/нормализация/лимитер

/// Upward-компрессор: поднимает тихие участки не больше чем в maxGain раз.
/// targetDb — уровень, к которому тянется огибающая.
final class UpwardCompressor {
    private let maxGain: Double
    private let target: Double
    private let attack: Double
    private let release: Double
    private var envelope = 0.0
    private var gain = 1.0

    init(maxGain: Double, targetDb: Double = -22.0, sampleRate: Double,
         attackMs: Double = 8.0, releaseMs: Double = 140.0) {
        self.maxGain = max(1.0, maxGain)
        target = pow(10.0, targetDb / 20.0)
        attack = 1.0 - exp(-1.0 / (sampleRate * attackMs / 1000.0))
        release = 1.0 - exp(-1.0 / (sampleRate * releaseMs / 1000.0))
    }

    func process(left: inout Double, right: inout Double) {
        let level = max(abs(left), abs(right))
        let envCoefficient = level > envelope ? attack : release
        envelope += (level - envelope) * envCoefficient
        let desired = envelope > 1e-9 ? min(maxGain, target / envelope) : 1.0
        let gainCoefficient = desired < gain ? attack : release
        gain += (desired - gain) * gainCoefficient
        left *= gain
        right *= gain
    }
}

/// Пиковый нормализатор для потока. Работает по блокам (кадрам SBC),
/// поэтому не «зудит» на каждом сэмпле. Для файлов используется глобальная
/// нормировка в OfflineAudioProcessor.
final class StreamingPeakNormalizer {
    private let target: Double
    private let maxGain: Double
    private let sampleRate: Double
    private let attackMs: Double
    private let releaseMs: Double
    private var gain = 1.0
    private var peak = 0.0

    init(target: Double, maxGain: Double = 8.0, sampleRate: Double,
         attackMs: Double = 8.0, releaseMs: Double = 250.0) {
        self.target = target
        self.maxGain = max(1.0, maxGain)
        self.sampleRate = sampleRate
        self.attackMs = attackMs
        self.releaseMs = releaseMs
    }

    func process(left: inout [Double], right: inout [Double]) {
        guard !left.isEmpty else { return }
        var blockPeak = 0.0
        for i in left.indices {
            blockPeak = max(blockPeak, abs(left[i] + right[i]))
        }
        // Коэффициенты считаются на блок: между вызовами проходит 128
        // сэмплов, а не один.
        let blockSeconds = Double(left.count) / sampleRate
        let attack = 1.0 - exp(-blockSeconds / max(0.0001, attackMs / 1000.0))
        let release = 1.0 - exp(-blockSeconds / max(0.0001, releaseMs / 1000.0))
        peak = max(blockPeak, peak + (blockPeak - peak) * release)
        let desired = blockPeak > 1e-9 ? min(maxGain, target / blockPeak) : gain
        if desired < gain {
            // Вниз — сразу, иначе на транзиенте сумма успевает выйти за
            // полную шкалу до следующего блока.
            gain = desired
        } else {
            gain += (desired - gain) * (desired < gain ? attack : release)
        }
        for i in left.indices {
            left[i] *= gain
            right[i] *= gain
        }
    }
}

/// ПИКОВЫЙ лимитер по сумме L+R. Общий gain для обоих каналов сохраняет
/// стереопанораму и гарантирует, что моно-динамик DS4 не получит сумму
/// выше ceiling.
final class MonoSumLimiter {
    let ceiling: Double
    private let release: Double
    private var envelope = 0.0
    private var gain = 1.0

    init(ceilingDb: Double, sampleRate: Double, releaseMs: Double = 60.0) {
        ceiling = pow(10.0, ceilingDb / 20.0)
        release = 1.0 - exp(-1.0 / (sampleRate * releaseMs / 1000.0))
    }

    func process(left: inout Double, right: inout Double) {
        let peak = abs(left + right)
        if peak > envelope {
            envelope = peak
        } else {
            envelope += (peak - envelope) * release
        }
        let desired = envelope > ceiling ? ceiling / envelope : 1.0
        if desired < gain {
            gain = desired
        } else {
            gain += (desired - gain) * release
        }
        left *= gain
        right *= gain
    }
}

// MARK: - Дизеринг и sample-and-hold

struct TpdfDither {
    private var state: UInt64

    init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        state = seed != 0 ? seed : 0x9E37_79B9_7F4A_7C15
    }

    /// Два независимых равномерных значения → треугольное распределение
    /// в пределах ±1 LSB.
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let u1 = Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0)
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let u2 = Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return u1 - u2
    }
}

final class SampleAndHold {
    private let step: Double
    private var phase = 1.0
    private var heldLeft = 0.0
    private var heldRight = 0.0

    init(rate: Double, sampleRate: Double) {
        step = max(0.0001, min(1.0, rate / sampleRate))
    }

    func process(left: inout Double, right: inout Double) {
        phase += step
        if phase >= 1.0 {
            phase -= floor(phase)
            heldLeft = left
            heldRight = right
        }
        left = heldLeft
        right = heldRight
    }
}

final class BitCrusher {
    private let levels: Double
    private let step: Double
    private var dither = TpdfDither()
    /// После mono-pre каналы одинаковы: одинаковый дизер сохраняет L=R.
    private let sharedDither: Bool

    init(bits: Int, sharedDither: Bool) {
        let clamped = max(1, min(24, bits))
        levels = pow(2.0, Double(clamped - 1))
        step = 1.0 / levels
        self.sharedDither = sharedDither
    }

    func process(left: inout Double, right: inout Double) {
        // TPDF: разность двух равномерных на [0,1) — треугольное
        // распределение в пределах ±1 LSB.
        let noiseLeft = dither.next() * step
        let noiseRight = sharedDither ? noiseLeft : dither.next() * step
        left = (left + noiseLeft) * levels
        left = left.rounded() / levels
        right = (right + noiseRight) * levels
        right = right.rounded() / levels
    }
}

// MARK: - Общий realtime-тракт

/// Обработка кадра 128 сэмплов. Порядок строго:
/// моно → HP → LP → mid → компрессия → нормализация → лимитер →
/// sample-and-hold → bitcrush.
final class StreamingDspProcessor {
    private let config: DspConfig
    private let filters: StereoFilterBank
    private let compressor: UpwardCompressor?
    private let normalizer: StreamingPeakNormalizer?
    private let limiter: MonoSumLimiter
    private let hold: SampleAndHold?
    private let crusher: BitCrusher?

    private(set) var inputPeakChannel = 0.0
    private(set) var inputPeakSum = 0.0
    private(set) var filtersPeakChannel = 0.0
    private(set) var filtersPeakSum = 0.0
    private(set) var compressionPeakChannel = 0.0
    private(set) var compressionPeakSum = 0.0
    private(set) var normalizationPeakChannel = 0.0
    private(set) var normalizationPeakSum = 0.0
    private(set) var limiterPeakChannel = 0.0
    private(set) var limiterPeakSum = 0.0
    private(set) var outputPeakChannel = 0.0
    private(set) var outputPeakSum = 0.0
    private(set) var processedFrames = 0
    /// Минимальный защитный gain после mid-boost (1 = защита не сработала).
    private(set) var filterSafetyGain = 1.0

    var stagePeaks: DspStagePeaks {
        var peaks = DspStagePeaks()
        peaks.inputChannel = inputPeakChannel
        peaks.inputSum = inputPeakSum
        peaks.afterFiltersChannel = filtersPeakChannel
        peaks.afterFiltersSum = filtersPeakSum
        peaks.afterCompressionChannel = compressionPeakChannel
        peaks.afterCompressionSum = compressionPeakSum
        peaks.afterNormalizationChannel = normalizationPeakChannel
        peaks.afterNormalizationSum = normalizationPeakSum
        peaks.afterLimiterChannel = limiterPeakChannel
        peaks.afterLimiterSum = limiterPeakSum
        peaks.outputChannel = outputPeakChannel
        peaks.outputSum = outputPeakSum
        return peaks
    }

    init(config: DspConfig) {
        self.config = config
        filters = StereoFilterBank(highpassHz: config.highpassHz,
                                   lowpassHz: config.lowpassHz,
                                   midBoostDb: config.midBoostDb,
                                   sampleRate: Double(config.sampleRate))
        compressor = config.compressMaxGain > 1.0
            ? UpwardCompressor(maxGain: config.compressMaxGain,
                               sampleRate: Double(config.sampleRate))
            : nil
        normalizer = config.normalize
            ? StreamingPeakNormalizer(target: config.normalizeTarget,
                                      maxGain: max(8.0, config.compressMaxGain),
                                      sampleRate: Double(config.sampleRate))
            : nil
        limiter = MonoSumLimiter(ceilingDb: config.limiterCeilingDb,
                                 sampleRate: Double(config.sampleRate))
        hold = config.downsampleHoldHz.map {
            SampleAndHold(rate: $0, sampleRate: Double(config.sampleRate))
        }
        crusher = config.bitcrushBits.map {
            BitCrusher(bits: $0, sharedDither: config.monoPre)
        }
    }

    func process(left: inout [Int16], right: inout [Int16]) {
        guard left.count == right.count else { return }
        let count = left.count
        var l = [Double](repeating: 0, count: count)
        var r = [Double](repeating: 0, count: count)
        for i in 0 ..< count {
            var lv = Double(left[i]) / 32768.0
            var rv = Double(right[i]) / 32768.0
            inputPeakChannel = max(inputPeakChannel, abs(lv), abs(rv))
            inputPeakSum = max(inputPeakSum, abs(lv + rv))
            if config.monoPre {
                lv = (lv + rv) * 0.5
                rv = lv
            }
            l[i] = lv
            r[i] = rv
        }

        if !filters.isEmpty {
            for i in 0 ..< count { filters.process(left: &l[i], right: &r[i]) }
        }
        // После пикового буста сумма L+R может превысить полную шкалу.
        // Уменьшаем весь кадр — это сохраняет форму сигнала и стерео.
        var framePeak = 0.0
        for i in 0 ..< count {
            framePeak = max(framePeak, abs(l[i] + r[i]))
        }
        if framePeak > 0.999 {
            let safety = 0.999 / framePeak
            for i in 0 ..< count {
                l[i] *= safety
                r[i] *= safety
            }
            filterSafetyGain = min(filterSafetyGain, safety)
            framePeak = 0.999
        }
        for i in 0 ..< count {
            filtersPeakChannel = max(filtersPeakChannel, abs(l[i]), abs(r[i]))
            filtersPeakSum = max(filtersPeakSum, abs(l[i] + r[i]))
        }
        if let compressor {
            for i in 0 ..< count { compressor.process(left: &l[i], right: &r[i]) }
        }
        // Компрессор поднимает тихие места; на громком материале сумма
        // может выйти за шкалу ещё до нормализации. Защищаемся сразу.
        var compressionPeak = 0.0
        for i in 0 ..< count { compressionPeak = max(compressionPeak, abs(l[i] + r[i])) }
        if compressionPeak > 0.999 {
            let safety = 0.999 / compressionPeak
            for i in 0 ..< count {
                l[i] *= safety
                r[i] *= safety
            }
        }
        for i in 0 ..< count {
            compressionPeakChannel = max(compressionPeakChannel, abs(l[i]), abs(r[i]))
            compressionPeakSum = max(compressionPeakSum, abs(l[i] + r[i]))
        }
        if let normalizer {
            normalizer.process(left: &l, right: &r)
        }
        if config.extraGain != 1.0 {
            for i in 0 ..< count {
                l[i] *= config.extraGain
                r[i] *= config.extraGain
            }
        }
        for i in 0 ..< count {
            normalizationPeakChannel = max(normalizationPeakChannel, abs(l[i]), abs(r[i]))
            normalizationPeakSum = max(normalizationPeakSum, abs(l[i] + r[i]))
        }
        for i in 0 ..< count {
            limiter.process(left: &l[i], right: &r[i])
            limiterPeakChannel = max(limiterPeakChannel, abs(l[i]), abs(r[i]))
            limiterPeakSum = max(limiterPeakSum, abs(l[i] + r[i]))
        }
        if let hold {
            for i in 0 ..< count { hold.process(left: &l[i], right: &r[i]) }
        }
        if let crusher {
            for i in 0 ..< count { crusher.process(left: &l[i], right: &r[i]) }
        }
        for i in 0 ..< count {
            outputPeakChannel = max(outputPeakChannel, abs(l[i]), abs(r[i]))
            outputPeakSum = max(outputPeakSum, abs(l[i] + r[i]))
            left[i] = Int16(max(-32768.0, min(32767.0, (l[i] * 32768.0).rounded())))
            right[i] = Int16(max(-32768.0, min(32767.0, (r[i] * 32768.0).rounded())))
        }
        processedFrames += count
    }
}

// MARK: - Offline-тракт (--play, --process-only)

enum OfflineAudioProcessor {
    static func process(left: [Int16], right: [Int16],
                        config: DspConfig) -> DspProcessResult {
        precondition(left.count == right.count)
        let count = left.count
        var l = [Double](repeating: 0, count: count)
        var r = [Double](repeating: 0, count: count)
        var peaks = DspStagePeaks()
        for i in 0 ..< count {
            var lv = Double(left[i]) / 32768.0
            var rv = Double(right[i]) / 32768.0
            peaks.inputChannel = max(peaks.inputChannel, abs(lv), abs(rv))
            peaks.inputSum = max(peaks.inputSum, abs(lv + rv))
            if config.monoPre {
                lv = (lv + rv) * 0.5
                rv = lv
            }
            l[i] = lv
            r[i] = rv
        }

        // HP → LP → mid boost.
        let filters = StereoFilterBank(highpassHz: config.highpassHz,
                                       lowpassHz: config.lowpassHz,
                                       midBoostDb: config.midBoostDb,
                                       sampleRate: Double(config.sampleRate))
        if !filters.isEmpty {
            for i in 0 ..< count { filters.process(left: &l[i], right: &r[i]) }
        }
        for i in 0 ..< count {
            peaks.afterFiltersChannel = max(peaks.afterFiltersChannel, abs(l[i]), abs(r[i]))
            peaks.afterFiltersSum = max(peaks.afterFiltersSum, abs(l[i] + r[i]))
        }

        // Защита от перегрузки уже после mid-boost: если фильтр/буст
        // вывели сумму выше полной шкалы, уменьшаем каскад, а не клиппим.
        var midBoostSafetyGain = 1.0
        if peaks.afterFiltersSum > 0.999 {
            midBoostSafetyGain = 0.999 / peaks.afterFiltersSum
            for i in 0 ..< count {
                l[i] *= midBoostSafetyGain
                r[i] *= midBoostSafetyGain
            }
            peaks.afterFiltersChannel *= midBoostSafetyGain
            peaks.afterFiltersSum *= midBoostSafetyGain
        }

        // Компрессия.
        if config.compressMaxGain > 1.0 {
            let compressor = UpwardCompressor(maxGain: config.compressMaxGain,
                                              sampleRate: Double(config.sampleRate))
            for i in 0 ..< count {
                compressor.process(left: &l[i], right: &r[i])
            }
        }
        var compressionPeak = 0.0
        for i in 0 ..< count { compressionPeak = max(compressionPeak, abs(l[i] + r[i])) }
        if compressionPeak > 0.999 {
            let safety = 0.999 / compressionPeak
            for i in 0 ..< count {
                l[i] *= safety
                r[i] *= safety
            }
        }
        for i in 0 ..< count {
            peaks.afterCompressionChannel = max(peaks.afterCompressionChannel, abs(l[i]), abs(r[i]))
            peaks.afterCompressionSum = max(peaks.afterCompressionSum, abs(l[i] + r[i]))
        }

        // Глобальная нормализация файла по пику суммы (или канала для
        // совместимости с --normalize-peak).
        var normalizationGain = 1.0
        if config.normalize {
            let measured = config.normalizeByChannelPeak
                ? peaks.afterCompressionChannel
                : peaks.afterCompressionSum
            if measured > 0 {
                normalizationGain = config.normalizeTarget / measured
                for i in 0 ..< count {
                    l[i] *= normalizationGain
                    r[i] *= normalizationGain
                }
            }
        }
        for i in 0 ..< count {
            peaks.afterNormalizationChannel = max(peaks.afterNormalizationChannel, abs(l[i]), abs(r[i]))
            peaks.afterNormalizationSum = max(peaks.afterNormalizationSum, abs(l[i] + r[i]))
        }

        if config.extraGain != 1.0 {
            for i in 0 ..< count {
                l[i] *= config.extraGain
                r[i] *= config.extraGain
            }
        }

        // Лимитер последним перед нелинейностями кодека.
        let limiter = MonoSumLimiter(ceilingDb: config.limiterCeilingDb,
                                     sampleRate: Double(config.sampleRate))
        for i in 0 ..< count {
            limiter.process(left: &l[i], right: &r[i])
            peaks.afterLimiterChannel = max(peaks.afterLimiterChannel, abs(l[i]), abs(r[i]))
            peaks.afterLimiterSum = max(peaks.afterLimiterSum, abs(l[i] + r[i]))
        }

        if let holdRate = config.downsampleHoldHz {
            let hold = SampleAndHold(rate: holdRate, sampleRate: Double(config.sampleRate))
            for i in 0 ..< count { hold.process(left: &l[i], right: &r[i]) }
        }
        if let bits = config.bitcrushBits {
            let crusher = BitCrusher(bits: bits, sharedDither: config.monoPre)
            for i in 0 ..< count { crusher.process(left: &l[i], right: &r[i]) }
        }
        // Sample-and-hold/дизеринг стоят после лимитера, поэтому здесь
        // нужен ещё один жёсткий контроль суммы. Нормируем весь блок,
        // а не обрезаем отдельные сэмплы (это сохраняет форму сигнала).
        var finalSumPeak = 0.0
        for i in 0 ..< count { finalSumPeak = max(finalSumPeak, abs(l[i] + r[i])) }
        if finalSumPeak > limiter.ceiling {
            let safety = limiter.ceiling / finalSumPeak
            for i in 0 ..< count {
                l[i] *= safety
                r[i] *= safety
            }
        }

        var outLeft = [Int16](repeating: 0, count: count)
        var outRight = [Int16](repeating: 0, count: count)
        for i in 0 ..< count {
            peaks.outputChannel = max(peaks.outputChannel, abs(l[i]), abs(r[i]))
            peaks.outputSum = max(peaks.outputSum, abs(l[i] + r[i]))
            outLeft[i] = Int16(max(-32768.0, min(32767.0, (l[i] * 32768.0).rounded())))
            outRight[i] = Int16(max(-32768.0, min(32767.0, (r[i] * 32768.0).rounded())))
        }
        return DspProcessResult(left: outLeft, right: outRight, peaks: peaks,
                                normalizationGain: normalizationGain,
                                midBoostSafetyGain: midBoostSafetyGain,
                                clippedBeforeOutput: peaks.afterFiltersSum > 0.999
                                    || peaks.afterCompressionSum > 1.0
                                    || peaks.afterNormalizationSum > 1.0)
    }
}
