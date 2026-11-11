#!/bin/bash
# Тест задержки в СИСТЕМНОМ режиме: щелчок из системы → динамик DS4.
#
# Перед запуском должен работать системный режим (в другом окне):
#   cd tools/ds4probe && ./ds4-system-audio.sh
#
# Что измеряем: задержку «система → BlackHole → захват → BT → динамик».
# Если щелчок слышен сразу после «НАЧАЛО» — весь тракт быстрый, и те ~3 с,
# что слышались раньше, набирались в приложении-источнике.

cd "$(dirname "$0")"

CLICK=/tmp/ds4_sys_click.wav
if [ ! -f "$CLICK" ]; then
    ffmpeg -hide_banner -loglevel error -f lavfi -i "sine=frequency=2000:duration=0.06" \
        -af "volume=6dB" -y "$CLICK" || exit 1
fi

echo "=== Тест задержки системного тракта ==="
echo "Слушайте щелчок из динамика DS4. Он должен прозвучать сразу после «НАЧАЛО»."
sleep 1
echo "3..."
sleep 1
echo "2..."
sleep 1
echo "1..."
sleep 1
echo "НАЧАЛО (щелчок ушёл в систему)"
afplay "$CLICK"
echo "(щелчок отправлен)"
sleep 2
