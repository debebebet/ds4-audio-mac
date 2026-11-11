#!/usr/bin/env python3
"""Отправляет тестовый PCM (1 кГц) в ds4probe через Unix-сокет.

Использование:
    python3 ds4-pcm-client.py /tmp/dolphin-ds4.sock 24000 3

Аргументы: путь к сокету, частота, длительность в секундах.
Формат блоков — `D4P1` (16-байтный заголовок + s16le).
"""

import math
import socket
import struct
import sys
import time


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__)
        return 2

    path = sys.argv[1]
    rate = int(sys.argv[2])
    seconds = float(sys.argv[3])

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(path)

    block = 120  # 5 мс при 24 кГц, как пакет ADPCM Wiimote
    total = int(rate * seconds / block)
    phase = 0.0
    step = 2 * math.pi * 1000.0 / rate
    started = time.time()

    for _ in range(total):
        payload = bytearray()
        for _ in range(block):
            payload += struct.pack("<h", int(12000 * math.sin(phase)))
            phase += step

        header = b"D4P1" + struct.pack("<IBBHI", rate, 1, 0, 0, block)
        sock.sendall(header + payload)

        target = started + (_ + 1) * block / rate
        delay = target - time.time()
        if delay > 0:
            time.sleep(delay)

    sock.close()
    print(f"sent {total * block} samples in {time.time() - started:.3f} s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
