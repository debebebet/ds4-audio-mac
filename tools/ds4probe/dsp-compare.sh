#!/bin/bash
# Сравнение DSP-пресетов на слух. Транспорт неизменен:
# 16 кГц, joint stereo, 8 подполос, 16 блоков, bitpool 12,
# отчёт 0x16 (10 кадров), громкость 0x4F.
#
# Использование:
#   ./dsp-compare.sh A|B|C|D|E|F [файл.wav|mp3] [секунды]
#   ./dsp-compare.sh all file.wav         # прогоны по 6 с с паузами
#
# Записи для прослушивания сохраняются в artifacts/dsp/compare_<пресет>.wav.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Относительный путь к файлу разрешаем от каталога, ОТКУДА запустили скрипт,
# а не от каталога скрипта.
INVOCATION_DIR="$PWD"
cd "$SCRIPT_DIR"
ROOT="$(cd ../../.. && pwd)"
BIN=./.build/release/ds4probe
FILE="${2:-$ROOT/ds4audio/artifacts/ps3-boot.wav}"
case "$FILE" in
    /*) ;;
    *) FILE="$INVOCATION_DIR/$FILE" ;;
esac
SECONDS_TO_RUN="${3:-6}"
OUT="$ROOT/ds4audio/artifacts/dsp"
mkdir -p "$OUT"

if [ ! -x "$BIN" ]; then
    echo "Сборка не найдена; соберите: cd $ROOT/ds4audio/tools/ds4probe && swift build -c release"
    exit 1
fi

COMMON=(--volume 0x4F --report 0x16 --frames 10 --bitpool 12 --rate 16000)

preset_flags() {
    case "$1" in
        A) ;;
        B) echo "--lowpass 4000 --highpass 350" ;;
        C) echo "--lowpass 4000 --highpass 350 --mid-boost 4" ;;
        D) echo "--lowpass 4000 --highpass 350 --mid-boost 4 --compress 8 --limit -1.4" ;;
        E) echo "--lowpass 4000 --highpass 350 --mid-boost 4 --compress 8 --limit -1.4 --allocation loudness" ;;
        F) echo "--lowpass 4000 --highpass 350 --mid-boost 4 --compress 8 --limit -1.4 --allocation loudness --bitcrush 8" ;;
        *) return 1 ;;
    esac
}

run_preset() {
    local name=$1
    local flags
    flags=$(preset_flags "$name") || { echo "неизвестный пресет: $name"; exit 2; }
    echo "=== Пресет $name: ${flags:-без флагов}"
    # shellcheck disable=SC2086
    "$BIN" --play "$FILE" --seconds "$SECONDS_TO_RUN" \
        --save-processed "$OUT/compare_$name.wav" \
        "${COMMON[@]}" $flags
}

if [ "${1:-}" = "all" ]; then
    for p in A B C D E F; do
        run_preset "$p"
        echo
        sleep 2
    done
else
    run_preset "${1:-A}"
fi
