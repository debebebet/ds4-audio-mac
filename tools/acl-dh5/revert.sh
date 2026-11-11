#!/bin/bash
# revert.sh — снять все эксперименты со sniff/ACL и вернуть систему в норму.
set -u
echo "== убираю ACLPacketTypes"
sudo /usr/bin/defaults delete /Library/Preferences/com.apple.MobileBluetooth.debugSettings ACLPacketTypes 2>/dev/null && echo "   удалён" || echo "   не было"
echo "== убираю UseLowLatencyGameController"
sudo /usr/bin/defaults delete /Library/Preferences/com.apple.Bluetooth UseLowLatencyGameController 2>/dev/null && echo "   удалён" || echo "   не было"
echo "== перезапускаю bluetoothd"
sudo /usr/bin/pkill -x bluetoothd || echo "   не удалось"
sleep 4
echo "   bluetoothd pid: $(pgrep -x bluetoothd || echo нет)"
echo "Готово. BT-устройства переподключатся сами."
