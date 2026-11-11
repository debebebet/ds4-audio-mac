import Foundation

/// Разбор WAV-файла (RIFF/WAVE, PCM 16-bit) и ресемплинг.
///
/// Нужен для проигрывателя: в контроллер уходит SBC 32 или 16 кГц, а исходник
/// может быть любой частоты.
struct WavFile {
    let sampleRate: Int
    let channels: Int
    /// Интерливнутые сэмплы (channels сэмплов на кадр).
    let samples: [Int16]

    var duration: Double { Double(samples.count / max(1, channels)) / Double(sampleRate) }

    /// Быстрая проверка, что файл — RIFF/WAVE (без чтения целиком).
    static func isWav(path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 12)) ?? Data()
        return head.count >= 12
            && head.prefix(4) == Data("RIFF".utf8)
            && head.subdata(in: 8 ..< 12) == Data("WAVE".utf8)
    }

    /// Разбор WAV. Поддерживается только PCM 16-bit — этого достаточно для
    /// тестовых сигналов и большинства коротких сэмплов.
    static func load(path: String) throws -> WavFile {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data)

        func u32(at offset: Int) -> UInt32 {
            guard offset + 4 <= bytes.count else { return 0 }
            return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }
        func u16(at offset: Int) -> UInt16 {
            guard offset + 2 <= bytes.count else { return 0 }
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }

        guard bytes.count > 44, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else {
            throw ProbeError.message("не WAV-файл (нет сигнатуры RIFF/WAVE)")
        }

        var offset = 12
        var sampleRate = 0
        var channels = 0
        var bitsPerSample = 0
        var dataStart = -1
        var dataLength = 0

        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let size = Int(u32(at: offset + 4))
            let body = offset + 8
            switch id {
            case "fmt ":
                channels = Int(u16(at: body + 2))
                sampleRate = Int(u32(at: body + 4))
                bitsPerSample = Int(u16(at: body + 14))
            case "data":
                dataStart = body
                dataLength = min(size, bytes.count - body)
            default:
                break
            }
            offset = body + size + (size % 2)  // чётное выравнивание
        }

        guard dataStart >= 0, channels > 0, sampleRate > 0 else {
            throw ProbeError.message("в WAV нет блока data или fmt")
        }
        guard bitsPerSample == 16 else {
            throw ProbeError.message("поддерживается только PCM 16 бит (в файле \(bitsPerSample))")
        }

        var samples: [Int16] = []
        samples.reserveCapacity(dataLength / 2)
        var i = dataStart
        let end = dataStart + (dataLength / 2) * 2
        while i + 1 < end {
            let v = Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
            samples.append(v)
            i += 2
        }
        return WavFile(sampleRate: sampleRate, channels: channels, samples: samples)
    }



    /// Компрессия динамики (бустинг тихих участков).
    ///
    /// Нужна потому, что тихие места материала (−40…−60 дБFS) на слух в
    /// контроллере просто исчезают: слышно «прерывания», хотя сам поток
    /// доставлен без потерь. Поднимаем тихие участки к общему уровню.
    func compressed(maxGain: Double = 8, targetDb: Double = -22, windowMs: Double = 20) -> WavFile {
        let n = samples.count
        guard n > 0, channels > 0 else { return self }
        let frameCount = n / channels
        let win = max(1, Int(Double(sampleRate) * windowMs / 1000.0))
        let target = pow(10.0, targetDb / 20.0)

        // Огибающая по окнам: RMS + сглаживание (быстрая атака, медленный спад).
        var env = [Double](repeating: 0, count: frameCount)
        var idx = 0
        while idx < frameCount {
            let end = min(frameCount, idx + win)
            var sum = 0.0
            for i in idx ..< end { let v = Double(samples[i * channels]); sum += v * v }
            let rms = sqrt(sum / Double(end - idx))
            env[idx] = rms
            idx = end
        }
        var smoothed = env
        var current = 0.0
        for i in 0 ..< frameCount {
            let attack: Double = env[i] > current ? 0.6 : 0.12
            current += (env[i] - current) * attack
            smoothed[i] = current
        }

        // Усиление с ограничением и последующим сглаживанием (чтобы не «качало»).
        var gains = [Double](repeating: 1, count: frameCount)
        for i in 0 ..< frameCount {
            let g = smoothed[i] > 1 ? min(maxGain, target / smoothed[i]) : 1
            gains[i] = g
        }
        for _ in 0 ..< 3 {
            var prev = gains[0]
            for i in 1 ..< frameCount {
                prev = (prev + gains[i] + gains[i - 1]) / 3.0
                gains[i] = prev
            }
        }

        var out = samples
        for i in 0 ..< frameCount {
            let g = gains[i]
            for c in 0 ..< channels {
                let v = Double(samples[i * channels + c]) * g
                out[i * channels + c] = Int16(max(-32768, min(32767, Int(v))))
            }
        }
        return WavFile(sampleRate: sampleRate, channels: channels, samples: out)
    }

    /// Запись обработанного сигнала в WAV (16 бит PCM).
    func write(to path: String) throws {
        // Длина должна быть кратна размеру кадра (channels × 2 байта),
        // иначе часть инструментов (включая Python wave) читает файл неверно.
        var values = samples
        let frameBytes = channels * 2
        if values.count % frameBytes != 0 {
            values.append(contentsOf: [Int16](repeating: 0, count: frameBytes - values.count % frameBytes))
        }
        var data = Data(capacity: values.count * 2)
        for v in values {
            let u = UInt16(bitPattern: v)
            data.append(UInt8(u & 0xFF))
            data.append(UInt8((u >> 8) & 0xFF))
        }
        let channels16 = UInt16(channels)
        let rate32 = UInt32(sampleRate)
        let bits16 = UInt16(16)
        let byteRate = UInt32(sampleRate * channels * 2)
        let blockAlign = UInt16(channels * 2)
        var header = Data()
        func append32(_ v: UInt32) { for b in [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] { header.append(b) } }
        func append16(_ v: UInt16) { header.append(UInt8(v & 0xFF)); header.append(UInt8((v >> 8) & 0xFF)) }
        header.append(contentsOf: Array("RIFF".utf8)); append32(UInt32(36 + data.count))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8)); append32(16); append16(1)
        append16(channels16); append32(rate32); append32(byteRate); append16(blockAlign); append16(bits16)
        header.append(contentsOf: Array("data".utf8)); append32(UInt32(data.count))
        var out = header
        out.append(data)
        try out.write(to: URL(fileURLWithPath: path))
    }

    /// Пиковый уровень файла.
    var peak: Int {
        var m = 0
        for v in samples { let a = v < 0 ? -Int(v) : Int(v); if a > m { m = a } }
        return m
    }

    /// Нормализация по пику: исходники часто тихие (например MP3-бутсаунд
    /// имеет пик −20 дБFS — на 19 дБ тише тестового тона).
    func normalized(peak target: Double) -> WavFile {
        let p = self.peak
        guard p > 0 else { return self }
        let scale = Double(Int16.max) * target / Double(p)
        var out = samples
        for i in 0 ..< out.count {
            let v = Double(out[i]) * scale
            out[i] = Int16(max(-32768, min(32767, Int(v))))
        }
        return WavFile(sampleRate: sampleRate, channels: channels, samples: out)
    }

    /// Пик суммы каналов (L+R). Динамик DS4 моно — контроллер складывает
    /// каналы, и если сумма выходит за полную шкалу, ЦАП клиппит (это
    /// кандидат на щелчки в звуке).
    var monoSumPeak: Int {
        guard channels >= 2 else { return peak }
        var m = 0
        var i = 0
        while i + 1 < samples.count {
            let sum = Int(samples[i]) + Int(samples[i + 1])
            let a = sum < 0 ? -sum : sum
            if a > m { m = a }
            i += 2
        }
        return m
    }

    /// Нормализация по пику суммы каналов: безопасно для моно-динамика DS4.
    func normalizedMonoSum(peak target: Double) -> WavFile {
        let p = monoSumPeak
        guard p > 0 else { return self }
        let scale = Double(Int16.max) * target / Double(p)
        var out = samples
        for i in 0 ..< out.count {
            let v = Double(out[i]) * scale
            out[i] = Int16(max(-32768, min(32767, Int(v))))
        }
        return WavFile(sampleRate: sampleRate, channels: channels, samples: out)
    }

    /// Линейное усиление.
    func amplified(_ gain: Double) -> WavFile {
        guard gain != 1 else { return self }
        var out = samples
        for i in 0 ..< out.count {
            let v = Double(out[i]) * gain
            out[i] = Int16(max(-32768, min(32767, Int(v))))
        }
        return WavFile(sampleRate: sampleRate, channels: channels, samples: out)
    }

    /// Обрезка тишины в начале и конце (порог в дБFS относительно полной шкалы).
    func trimmedSilence(thresholdDb: Double = -50) -> WavFile {
        let limit = Int(Double(Int16.max) * pow(10.0, thresholdDb / 20.0))
        let frameCount = samples.count / max(1, channels)
        var first = 0
        while first < frameCount {
            let a = abs(Int(samples[first * channels]))
            if a > limit { break }
            first += 1
        }
        var last = frameCount - 1
        while last > first {
            let a = abs(Int(samples[last * channels]))
            if a > limit { break }
            last -= 1
        }
        guard last >= first, first < frameCount else { return self }
        let slice = samples[(first * channels)...(min(last + 1, frameCount) * channels)]
        return WavFile(sampleRate: sampleRate, channels: channels, samples: Array(slice))
    }

    /// Полный стереосигнал, ресемплированный в targetRate.
    ///
    /// Для --play обработка идёт целым файлом: фильтры сохраняют состояние
    /// между блоками, а нормализация должна видеть глобальный пик.
    func decodedStereo(targetRate: Int) -> (left: [Int16], right: [Int16]) {
        let ratio = Double(targetRate) / Double(sampleRate)
        let totalOut = Int(Double(samples.count / max(1, channels)) * ratio)
        guard totalOut > 0 else { return ([], []) }

        // Линейная интерполяция по исходному сигналу.
        var left = [Int16](repeating: 0, count: totalOut)
        var right = [Int16](repeating: 0, count: totalOut)
        let sourceFrames = samples.count / max(1, channels)
        for i in 0 ..< totalOut {
            let src = Double(i) / ratio
            let i0 = Int(src)
            let i1 = min(i0 + 1, sourceFrames - 1)
            let frac = src - Double(i0)
            let a = Double(samples[i0 * channels])
            let b = Double(samples[i1 * channels])
            let l = a + (b - a) * frac
            left[i] = Int16(max(-32768, min(32767, Int32(l))))
            if channels >= 2 {
                let ra = Double(samples[i0 * channels + 1])
                let rb = Double(samples[i1 * channels + 1])
                let r = ra + (rb - ra) * frac
                right[i] = Int16(max(-32768, min(32767, Int32(r))))
            } else {
                right[i] = left[i]
            }
        }
        return (left, right)
    }

    /// Разбивка на кадры по 128 сэмплов на канал с ресемплингом в targetRate.
    ///
    /// Возвращает массив кадров: каждый — 128 сэмплов левого и правого канала.
    func frames(targetRate: Int, frameSamples: Int = 128) -> [(left: [Int16], right: [Int16])] {
        let (decodedLeft, decodedRight) = decodedStereo(targetRate: targetRate)
        var result: [(left: [Int16], right: [Int16])] = []
        var pos = 0
        while pos + frameSamples <= decodedLeft.count {
            result.append((Array(decodedLeft[pos ..< pos + frameSamples]),
                           Array(decodedRight[pos ..< pos + frameSamples])))
            pos += frameSamples
        }
        return result
    }

    static func stereo(sampleRate: Int, left: [Int16], right: [Int16]) -> WavFile {
        var interleaved = [Int16](repeating: 0, count: left.count * 2)
        for i in left.indices {
            interleaved[i * 2] = left[i]
            interleaved[i * 2 + 1] = right[i]
        }
        return WavFile(sampleRate: sampleRate, channels: 2, samples: interleaved)
    }
}
