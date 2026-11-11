#!/usr/bin/env python3
"""Анализ записи микрофоном: огибающая, провалы, высота тона.

Вход: WAV (PCM16 mono, любой частоты) — снят микрофоном макбука, в него
играет динамик DS4. Выход: уровень по окнам, список провалов (глитчей),
оценка высоты тона (Goertzel) и оценка темпа воспроизведения.

Использование: analyze.py <wav> [ожидаемая_частота_Гц]
"""
import array
import math
import sys
import wave


def read_wav(path):
    with wave.open(path, "rb") as w:
        nch, sw, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if sw != 2:
        raise SystemExit(f"нужен PCM16, получено {sw} байт/сэмпл")
    a = array.array("h")
    a.frombytes(raw)
    if nch == 2:
        a = array.array("h", [(a[i] + a[i + 1]) // 2 for i in range(0, len(a), 2)])
    return a, sr


def goertzel(samples, sr, freq):
    """Амплитуда частоты freq в сигнале samples (моно, PCM16)."""
    k = 2.0 * math.cos(2.0 * math.pi * freq / sr)
    s1 = s2 = 0.0
    for x in samples:
        s0 = x + k * s1 - s2
        s2, s1 = s1, s0
    return math.sqrt(max(0.0, s1 * s1 + s2 * s2 - k * s1 * s2)) * 2.0 / len(samples)


def main():
    path = sys.argv[1]
    expect = float(sys.argv[2]) if len(sys.argv) > 2 else 1000.0
    samples, sr = read_wav(path)
    dur = len(samples) / sr
    print(f"файл: {path}")
    print(f"длительность: {dur:.2f} с, частота: {sr} Гц, сэмплов: {len(samples)}")

    win = int(0.010 * sr)  # 10 мс
    env = []
    for i in range(0, len(samples) - win, win):
        chunk = samples[i:i + win]
        env.append(math.sqrt(sum(float(x) * x for x in chunk) / win))

    peak = max(env) if env else 0.0
    floor = sorted(env)[len(env) // 10] if env else 0.0
    print(f"огибающая: пик {peak:.0f}, шум (10 % квантиль) {floor:.0f}")

    # Активный участок: окна громче порога между шумом и пиком.
    thr = max(floor * 3.0, peak * 0.12)
    active = [i for i, v in enumerate(env) if v > thr]
    if not active:
        print("СИГНАЛА НЕТ — динамик молчал (или микрофон не поймал).")
        return
    lo, hi = active[0], active[-1]
    print(f"активный участок: {lo * 0.01:.2f}…{hi * 0.01:.2f} с "
          f"(длительность {(hi - lo) * 0.01:.2f} с, окон {len(active)})")

    # Провалы: окна активного участка ниже 25 % от среднего уровня сигнала.
    seg = env[lo:hi + 1]
    mean = sum(seg) / len(seg)
    gap_thr = max(floor * 3.0, mean * 0.25)
    dips = [i for i, v in enumerate(seg) if v <= gap_thr]
    # Склеиваем соседние окна в провалы.
    gaps = []
    for i in dips:
        if gaps and i - gaps[-1][1] <= 2:
            gaps[-1][1] = i
        else:
            gaps.append([i, i])
    print(f"средний уровень сигнала: {mean:.0f}; порог провала {gap_thr:.0f}")
    print(f"провалов: {len(gaps)}")
    for a, b in gaps[:40]:
        t0 = (lo + a) * 0.01
        print(f"  провал {t0:6.2f} с, длительность {(b - a + 1) * 0.01:.3f} с")

    # Высота тона на устойчивых участках (берём окна с уровнем > 60 % среднего).
    strong = [i for i, v in enumerate(seg) if v > mean * 0.6]
    if strong:
        i0, i1 = strong[0], strong[-1]
        chunk = samples[(lo + i0) * win:(lo + i1) * win]
        best = None
        for f in range(200, 4000, 5):
            amp = goertzel(chunk, sr, f)
            if best is None or amp > best[1]:
                best = (f, amp)
        print(f"высота тона: {best[0]} Гц (ожидали {expect:g}); "
              f"отклонение {100.0 * (best[0] - expect) / expect:+.2f} %")

    # Оценка темпа: число «всплесков» огибающей — для тона лучше считать
    # пересечения нуля на детектированной частоте.
    if strong:
        chunk = samples[(lo + strong[0]) * win:(lo + strong[-1]) * win]
        # грубая оценка частоты через пересечения нуля
        zc = 0
        for i in range(1, len(chunk)):
            if chunk[i - 1] <= 0 < chunk[i]:
                zc += 1
        if zc > 1:
            print(f"частота по пересечениям нуля: {zc * sr / (2 * len(chunk)):.1f} Гц")


if __name__ == "__main__":
    main()
