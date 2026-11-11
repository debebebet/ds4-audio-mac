#!/bin/bash
# Удаляет драйвер «DualShock 4». Нужны права root.
set -euo pipefail

DEST="/Library/Audio/Plug-Ins/HAL/DS4AudioDriver.driver"

if [ "${EUID}" -ne 0 ]; then
    echo "Запустите через sudo: sudo $0"
    exit 1
fi

echo "→ Удаление $DEST"
rm -rf "$DEST"

echo "→ Перезапуск coreaudiod"
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall -9 coreaudiod || true

echo "Готово."
