#!/bin/bash
# set-acl.sh — попросить bluetoothd использовать более крупные ACL-пакеты.
#
# Зачем: замеры показали, что на один пакет приходится ровно 83 байта
# полезной нагрузки (5 служебных L2CAP+HIDP + 78 отчёта) за окно ~15.2 мс.
# 83 байта — это ровно 3-DH1 (1 слот, EDR). Переход на 3-DH5 (5 слотов,
# до 1021 B, ограничение L2CAP MTU = 672 B) даёт до 672 B за то же окно,
# то есть до ~43 КБ/с вместо 5.5 — этого хватит на 32 кГц joint bp48.
#
# Требует sudo: bluetoothd работает от root и читает системный домен
# (/Library/Preferences). Пользовательская запись `defaults write` без sudo
# уходит в ~/Library/Preferences и демоном НЕ читается (проверено).
#
# Использование:
#   ./set-acl.sh                 # все EDR-пакеты (3-DH1/3/5, 2-DH1/3/5)
#   ./set-acl.sh 3-DH5 3-DH3     # только указанные
#   ./revert.sh                  # откат

set -u

DOMAIN="/Library/Preferences/com.apple.MobileBluetooth.debugSettings"
KEY="ACLPacketTypes"

if [ $# -eq 0 ]; then
    PACKETS=(3-DH5 3-DH3 3-DH1 2-DH5 2-DH3 2-DH1)
else
    PACKETS=("$@")
fi

echo "== 1/4 сохраняю текущее значение (для отката)"
mkdir -p "$(dirname "$0")/backup"
sudo defaults read "$DOMAIN" "$KEY" > "$(dirname "$0")/backup/acl-before.txt" 2>/dev/null \
    && echo "   было: $(cat "$(dirname "$0")/backup/acl-before.txt")" \
    || echo "   ключа не было (откат = удалить ключ)"

echo "== 2/4 записываю ACLPacketTypes = ${PACKETS[*]}"
sudo /usr/bin/defaults write "$DOMAIN" "$KEY" -array "${PACKETS[@]}"
sudo /usr/bin/defaults read "$DOMAIN" | sed 's/^/   /'

echo "== 3/4 перезапускаю bluetoothd (все BT-устройства отключатся на ~10-20 с)"
# launchctl kickstart заблокирован SIP, но SIGTERM для LaunchDaemon разрешён:
# launchd поднимет демон заново.
sudo /usr/bin/pkill -x bluetoothd || echo "   ВНИМАНИЕ: не удалось остановить bluetoothd"
for i in $(seq 1 20); do
    if pgrep -x bluetoothd >/dev/null 2>&1; then
        sleep 1
    else
        sleep 1
        break
    fi
done
echo "   bluetoothd pid: $(pgrep -x bluetoothd || echo 'пока нет')"

echo "== 4/4 жду, пока DS4 переподключится (до 60 с)"
for i in $(seq 1 60); do
    if /usr/sbin/system_profiler SPBluetoothDataType 2>/dev/null \
        | grep -A2 "DUALSHOCK 4" | grep -q "Connected: Yes"; then
        echo "   DS4 на связи"
        break
    fi
    sleep 1
done

echo
echo "Готово. Проверка (запускать вне sudo, из корня репозитория):"
echo "    ./tools/bwbench/fill 3"
echo "Если 526 B по-прежнему идёт ~9.8 отч/с (≈5 КБ/с) — настройка не применилась."
echo "Если стало в разы быстрее — переходим на 32 кГц / bp48 и профиль 0x17."
echo "Откат: ./revert.sh"
