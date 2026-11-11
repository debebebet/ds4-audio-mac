#!/bin/bash
# DS4 как системное аудиоустройство на macOS.
#
# Цепочка:  любой плеер/приложение → «DualShock 4» (loopback-драйвер)
#           → захват в ds4probe → SBC 16 кГц → Bluetooth HID → динамик DS4
#
# Требования:
#   * Драйвер «DualShock 4» установлен: sudo tools/ds4driver/install-driver.sh
#     (без него скрипт попробует legacy-вариант через BlackHole 2ch)
#   * DualShock 4 подключён по Bluetooth
#
# Запуск:   ./ds4-system-audio.sh            (1 час, Ctrl-C для выхода)
#           STREAM_SECONDS=600 ./ds4-system-audio.sh
#
# Ctrl-C возвращает системный вывод на прежнее устройство автоматически.
# Если процесс убили жёстко — вернуть вручную:
#   ./.build/release/ds4probe --restore-output

set -uo pipefail
cd "$(dirname "$0")"

SECONDS_TO_RUN="${STREAM_SECONDS:-3600}"
CAPTURE_GAIN="${CAPTURE_GAIN:-16.0}"
# Уровень динамика DS4: 0x4F=100 %, 0x3F=80 %, 0x38=71 %, 0x18=30 %.
# 0x18 — рабочая громкость (выбрана пользователем 2026-11-09).
VOLUME="${VOLUME:-0x18}"

if [ ! -x ./.build/release/ds4probe ]; then
    echo "Сборка не найдена, собираю…"
    swift build -c release || exit 1
fi

AUDIO_LIST=$(./.build/release/ds4probe --list-audio)
if echo "$AUDIO_LIST" | grep -qi "DualShock 4"; then
    CAPTURE_DEVICE="DualShock 4"
    MODE="DualShock 4 (loopback-драйвер)"
elif echo "$AUDIO_LIST" | grep -qi "BlackHole"; then
    CAPTURE_DEVICE="BlackHole"
    MODE="BlackHole 2ch (legacy)"
else
    echo "Не найден ни драйвер «DualShock 4», ни BlackHole." >&2
    echo "Установите драйвер: sudo tools/ds4driver/install-driver.sh" >&2
    exit 1
fi

echo "Запуск: DS4 = системное аудиоустройство ($MODE → SBC 16 кГц → динамик DS4)"
echo "Громкость динамика: $VOLUME, усиление захвата: $CAPTURE_GAIN"
echo "Остановка: Ctrl-C (системный вывод вернётся сам)"

exec ./.build/release/ds4probe \
    --transport bluetooth \
    --wait 8 \
    --seconds "$SECONDS_TO_RUN" \
    --volume "$VOLUME" \
    --rate 16000 \
    --bitpool 12 \
    --report 0x16 \
    --frames 10 \
    --target speaker \
    --system-audio \
    --capture-device "$CAPTURE_DEVICE" \
    --capture-gain "$CAPTURE_GAIN" \
    --set-default-output \
    "$@"
