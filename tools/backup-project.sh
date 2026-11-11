#!/bin/bash
# Полный бэкап проекта ds4audio в backups/.
#
# Схема: rsync-копия во временный каталог с исключениями тяжёлых
# папок и бинарников, затем архив через ditto (сохраняет xattr/ACL).
#
# Исключаются: сборочные каталоги, кэши, чужие/реверс-исходники,
# исполняемые файлы и объекты (Mach-O, .exe/.dll, .o/.a),
# служебные файлы .DS_Store и сам каталог backups/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="$ROOT/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
ZIP="$BACKUP_DIR/ds4audio-backup-$STAMP.zip"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$BACKUP_DIR"

echo "→ Копирование проекта во временный каталог…"
rsync -a \
    --exclude='.build/' \
    --exclude='.build-*/' \
    --exclude='.npm-cache/' \
    --exclude='build/' \
    --exclude='tools/rea/' \
    --exclude='refs/' \
    --exclude='backups/' \
    --exclude='.DS_Store' \
    --exclude='*.exe' \
    --exclude='*.dll' \
    --exclude='*.dylib' \
    --exclude='*.so' \
    --exclude='*.o' \
    --exclude='*.a' \
    --exclude='*.lib' \
    --exclude='*.pcm' \
    "$ROOT/" "$STAGING/ds4audio/"

FILE_COUNT="$(find "$STAGING/ds4audio" -type f | wc -l | tr -d ' ')"
echo "→ Файлов в копии: $FILE_COUNT"

# Готовое universal-приложение кладём отдельно в dist/, чтобы архив
# содержал и сам артефакт, а не только исходники.
APP="$ROOT/tools/ds4gui/build/DualShock 4 Audio.app"
if [ -d "$APP" ]; then
    echo "→ Добавляю собранное приложение в dist/…"
    mkdir -p "$STAGING/ds4audio/dist"
    /usr/bin/ditto "$APP" "$STAGING/ds4audio/dist/DualShock 4 Audio.app"
    FILE_COUNT="$(find "$STAGING/ds4audio" -type f | wc -l | tr -d ' ')"
fi

echo "→ Упаковка в $ZIP …"
ditto -c -k --sequesterRsrc --keepParent "$STAGING/ds4audio" "$ZIP"

echo "→ Проверка целостности архива…"
unzip -tqq "$ZIP" >/dev/null

SIZE="$(du -h "$ZIP" | cut -f1 | tr -d ' ')"
echo "Готово: $ZIP ($SIZE, $FILE_COUNT файлов)"
