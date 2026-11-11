# reconnect — стабильность Bluetooth-линка с DS4

Утилиты на случай, когда контроллер «отваливается»: помогают понять,
виноват линк или код, и вернуть соединение без выдёргивания батареи.

| Файл | Что делает |
|---|---|
| `monitor` | **пассивный** монитор: раз в секунду печатает `CONNECTED`/`---`, наличие HID-интерфейса и число обрывов. Ничего не подключает — безопасно запускать в любой момент. |
| `probe` | то же, но при обрыве пытается `openConnection` и печатает список SDP-сервисов. |
| `ds4-reconnect` | держит соединение живым N секунд (по умолчанию 120), переподключаясь при обрыве. |

## Как пользоваться

```bash
cd tools/reconnect

# MAC-адрес контроллера можно задать явно:
export DS4_ADDRESS='AA:BB:CC:DD:EE:FF'

# просто посмотреть, держится ли линк (безопасно, ничего не меняет)
./monitor 20

# вернуть контроллер, если он уснул
./probe 5
```

Запускать **вне песочницы** (нужен доступ к Bluetooth):
в песочнице `IOBluetooth` показывает `powerState = 0` и пустой список.

## Что означает вывод `monitor`

```
[  0s] CONNECTED  hid=1  drops=0     ← всё в порядке
[  3s] ---        hid=0  drops=1     ← линк упал
```

* `hid=1` — HID-интерфейс опубликован, то есть хост-сторона в порядке;
* `hid=0` при `CONNECTED` — контроллер подключён, но HID не встал
  (обычно протухший link key);
* частые `drops` при заряженной батарее — признак сбоя сопряжения:
  удалить устройство в Настройках → Bluetooth и спарить заново.

## Сборка

```bash
clang -fobjc-arc -framework Foundation -framework IOBluetooth -framework IOKit monitor.m -o monitor
clang -fobjc-arc -framework Foundation -framework IOBluetooth -framework IOKit probe.m    -o probe
clang -fobjc-arc -framework Foundation -framework IOBluetooth ds4-reconnect.m -o ds4-reconnect
```
