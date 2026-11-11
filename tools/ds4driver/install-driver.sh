#!/bin/bash
# Устанавливает драйвер в системную папку HAL. Нужны права root.
set -euo pipefail
cd "$(dirname "$0")"

DEST="/Library/Audio/Plug-Ins/HAL/DS4AudioDriver.driver"
SOURCE="$PWD/build/DS4AudioDriver.driver"

if [ "${EUID}" -ne 0 ]; then
    echo "Запустите через sudo: sudo $0"
    exit 1
fi

if [ ! -d "$SOURCE" ]; then
    echo "Сначала соберите драйвер: ./build.sh"
    exit 1
fi

echo "→ Установка $DEST"
rm -rf "$DEST"
cp -R "$SOURCE" "$DEST"
chown -R root:wheel "$DEST"
chmod -R go-w "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "→ Перезапуск coreaudiod"
launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall -9 coreaudiod || true

echo "Готово. Устройство «DualShock 4» должно появиться в Настройках звука."
