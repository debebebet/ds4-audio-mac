#!/bin/bash
# Тест задержки аудио DS4 в ПРЯМОМ режиме (без системного тракта).
#
# Что делает: запускает зонд с файлом-тоном, который начинается сразу.
# Через сколько секунд после «…НАЧАЛО» вы услышите тон:
#   ~0.2 с  → задержка не в контроллере (она в системе/приложении);
#   ~3   с  → задержка внутри контроллера (DSP копит очередь).
#
# ВАЖНО: перед запуском остановите системный режим (он держит контроллер):
#   pkill -f "ds4probe --transport bluetooth" || true

cd "$(dirname "$0")"
BIN=./.build/release/ds4probe
TONE=/tmp/ds4_latency_tone.wav

if [ ! -x "$BIN" ]; then
    echo "Сборка не найдена, собираю…"
    swift build -c release || exit 1
fi

if [ ! -f "$TONE" ]; then
    ffmpeg -hide_banner -loglevel error -f lavfi -i "sine=frequency=1000:duration=8" \
        -af "volume=6dB" -y "$TONE" || exit 1
fi

echo "=== Тест задержки DS4 (прямой режим) ==="
echo "Слушайте: тон должен начаться сразу после отсчёта."
echo "Засекайте, через сколько секунд вы услышите тон."
sleep 1
echo "3..."
sleep 1
echo "2..."
sleep 1
echo "1..."
sleep 1
echo "НАЧАЛО (звук пошёл)"

"$BIN" --transport bluetooth --wait 1 --seconds 8 \
    --volume 0x18 --rate 16000 --bitpool 12 --report 0x16 --frames 10 --target speaker \
    --play "$TONE"

echo "=== Тест окончен ==="
