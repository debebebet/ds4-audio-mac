#!/bin/bash
# Собирает universal .app-бандл (arm64 + x86_64): GUI + стример ds4probe
# + HAL-драйвер «DualShock 4» внутри Resources.
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(cd ../.. && pwd)"
PROBE_DIR="$ROOT/tools/ds4probe"
DRIVER_DIR="$ROOT/tools/ds4driver"
APP_DIR="$PWD/build/DualShock 4 Audio.app"
UNIVERSAL_DIR="$PWD/build/universal"

ARM_TRIPLE="arm64-apple-macosx13.0"
X86_TRIPLE="x86_64-apple-macosx13.0"

echo "→ Сборка аудиодрайвера «DualShock 4» (universal)…"
(cd "$DRIVER_DIR" && ./build.sh)

echo "→ Сборка ds4probe (arm64)…"
(cd "$PROBE_DIR" && swift build -c release --triple "$ARM_TRIPLE" \
    --scratch-path .build-arm64)

echo "→ Сборка ds4probe (x86_64)…"
(cd "$PROBE_DIR" && swift build -c release --triple "$X86_TRIPLE" \
    --scratch-path .build-x86_64)

echo "→ Сборка DS4Audio (arm64)…"
swift build -c release --triple "$ARM_TRIPLE" --scratch-path .build-arm64

echo "→ Сборка DS4Audio (x86_64)…"
swift build -c release --triple "$X86_TRIPLE" --scratch-path .build-x86_64

echo "→ Сборка universal-бинарников…"
rm -rf "$UNIVERSAL_DIR"
mkdir -p "$UNIVERSAL_DIR"
lipo -create \
    "$PROBE_DIR/.build-arm64/release/ds4probe" \
    "$PROBE_DIR/.build-x86_64/release/ds4probe" \
    -output "$UNIVERSAL_DIR/ds4probe"
lipo -create \
    ".build-arm64/release/DS4Audio" \
    ".build-x86_64/release/DS4Audio" \
    -output "$UNIVERSAL_DIR/DS4Audio"

echo "→ Сборка .app…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$UNIVERSAL_DIR/DS4Audio" "$APP_DIR/Contents/MacOS/DS4Audio"
cp "$UNIVERSAL_DIR/ds4probe" "$APP_DIR/Contents/Resources/ds4probe"
cp -R "$DRIVER_DIR/build/DS4AudioDriver.driver" "$APP_DIR/Contents/Resources/"
chmod +x "$APP_DIR/Contents/MacOS/DS4Audio" "$APP_DIR/Contents/Resources/ds4probe"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ru</string>
    <key>CFBundleDisplayName</key>
    <string>DualShock 4 Audio</string>
    <key>CFBundleExecutable</key>
    <string>DS4Audio</string>
    <key>CFBundleIdentifier</key>
    <string>com.ds4audio.gui</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>DualShock 4 Audio</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Захват системного звука из loopback-устройства «DualShock 4» для передачи на геймпад.</string>
</dict>
</plist>
PLIST

# Локальная ad-hoc подпись: без неё macOS может ругаться на неподписанный
# бандл и сбрасывать разрешения при каждом запуске.
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || {
    echo "⚠️  ad-hoc подпись не удалась — приложение всё равно собрано"
}

echo ""
echo "Архитектуры:"
lipo -info "$APP_DIR/Contents/MacOS/DS4Audio"
lipo -info "$APP_DIR/Contents/Resources/ds4probe"
lipo -info "$APP_DIR/Contents/Resources/DS4AudioDriver.driver/Contents/MacOS/DS4AudioDriver"
echo ""
echo "Готово: $APP_DIR"
echo "Запуск:  open \"$APP_DIR\""
