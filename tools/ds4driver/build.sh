#!/bin/bash
# Собирает DS4AudioDriver.driver — виртуальное аудиоустройство «DualShock 4».
# Результат — universal-бандл (arm64 + x86_64).
set -euo pipefail
cd "$(dirname "$0")"

BUILD_DIR="$PWD/build"
BUNDLE="$BUILD_DIR/DS4AudioDriver.driver"
VENDOR="$PWD/vendor/libASPL"
MIN_MACOS="13.0"

echo "→ Сборка драйвера (universal: arm64 + x86_64)…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"

clang++ \
    -std=c++17 -O2 -DNDEBUG -fPIC \
    -arch arm64 -arch x86_64 \
    -mmacosx-version-min="$MIN_MACOS" \
    -I "$VENDOR/include" \
    -bundle \
    Driver.cpp "$VENDOR"/src/*.cpp \
    -framework CoreFoundation \
    -framework CoreAudio \
    -o "$BUNDLE/Contents/MacOS/DS4AudioDriver"

cp Info.plist "$BUNDLE/Contents/Info.plist"
mkdir -p "$BUNDLE/Contents/Resources"
cp "$VENDOR/LICENSE" "$BUNDLE/Contents/Resources/LICENSE-libASPL.txt"

# Ad-hoc подпись. Для локальной установки этого достаточно; для
# распространения приложения нужна Developer ID-подпись и нотаризация.
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || {
    echo "⚠️  ad-hoc подпись драйвера не удалась"
}

echo "Архитектуры:"
lipo -info "$BUNDLE/Contents/MacOS/DS4AudioDriver"
echo "Готово: $BUNDLE"
