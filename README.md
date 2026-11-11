# DS4 Audio

[English](#english) | [Русский](#русский)

## English

DS4 Audio is an experimental macOS GPLv3-or-later project for sending audio
to a Sony DualShock 4 through its vendor-specific Bluetooth HID audio path.
The controller is not exposed as a normal A2DP/HFP audio device: audio is
encoded as SBC frames and placed into HID output reports.

### What is included

- `tools/ds4probe/` — command-line Bluetooth streamer and protocol probe.
- `tools/ds4driver/` — virtual CoreAudio “DualShock 4” loopback device based on
  the vendored MIT-licensed libASPL library.
- Bluetooth/HID/L2CAP diagnostics and bandwidth experiments under `tools/`.
- A vendored SBC implementation under `tools/ds4probe/Sources/CSBC/`, retaining
  its original LGPL-2.1-or-later notices.

The SwiftUI GUI is maintained separately on the `gui-system-audio` branch.
This `main` branch contains the shared streamer, driver, and diagnostics.

### Requirements

- macOS 13 or newer.
- Xcode Command Line Tools or Xcode with Swift 5.9-compatible tooling.
- A DualShock 4 paired over Bluetooth for hardware streaming.
- Administrator access when installing the virtual audio driver.

Bluetooth and audio hardware tests must be run outside a restricted/sandboxed
environment.

### Build the streamer

```bash
cd tools/ds4probe
swift build -c release
```

### Build and install the virtual audio driver

```bash
cd tools/ds4driver
./build.sh
sudo ./install-driver.sh
```

The driver exposes a temporary CoreAudio device named **DualShock 4** while
the streamer is running. It allows system audio to be captured and encoded
for the controller.

**Warning:** driver installation changes the system CoreAudio HAL directory
and requires administrator authentication. Install it only if you understand
the consequences and have reviewed the source. To remove it:

```bash
cd tools/ds4driver
sudo ./uninstall-driver.sh
```

### Pair a controller

1. Disconnect the USB cable.
2. Hold **Share + PS** until the light bar flashes.
3. Open macOS **System Settings → Bluetooth** and select **Wireless
   Controller**.
4. Keep the controller awake and verify it appears as a Bluetooth HID device.

The built-in speaker path does not work over USB. If several controllers are
paired, diagnostic tools that need a specific device use `DS4_ADDRESS`:

```bash
export DS4_ADDRESS='AA:BB:CC:DD:EE:FF'
./tools/reconnect/monitor 20
```

Find the address in **System Information → Bluetooth**, or inspect the
controller's `addressString` with the project's Bluetooth tools. Do not
publish a real personal Bluetooth address in scripts, logs, or commits.

### Run a system-audio stream

```bash
cd tools/ds4probe
./ds4-system-audio.sh
```

The script selects the “DualShock 4” loopback device, streams a conservative
16 kHz SBC profile, and restores the previous system output when stopped.

### Architecture and limitations

```text
macOS applications
        ↓
CoreAudio “DualShock 4” loopback driver
        ↓
ds4probe: capture → resample → SBC → HID reports
        ↓
DualShock 4 Bluetooth speaker or headphone output
```

The profile is constrained by the macOS Bluetooth HID link and the controller
firmware. Quality and throughput are therefore lower than ordinary A2DP audio.
The project is experimental and requires a real controller for validation.

### Troubleshooting

- **No controller found:** pair it again, disconnect USB, wake it with PS, and
  check that Bluetooth is enabled. For a targeted diagnostic, set
  `DS4_ADDRESS` as shown above.
- **No sound:** install the HAL driver, run `ds4probe --list-audio`, select
  **DualShock 4** as the system output when using loopback mode, and confirm
  that the streamer is running. Stop competing Bluetooth/HID test programs.
- **The driver is installed but no device appears:** restart the streamer;
  the virtual device is intentionally published only while the driver
  heartbeat is active. Reinstall after a macOS update if necessary.
- **Audio is intermittent:** use the default 16 kHz/bitpool 12 profile. The
  macOS Bluetooth HID link has a substantially lower budget than A2DP.

### Disclaimer

This is an independent, experimental project and is **not affiliated with,
endorsed by, sponsored by, or approved by Sony Interactive Entertainment,
Sony Corporation, or PlayStation**. “DualShock 4” and PlayStation marks belong
to their respective owners. Use the software at your own risk; it may change
audio routing, install a system driver, or fail after macOS updates.

### Licensing

Project-owned code is licensed under **GNU GPLv3 or any later version**. See
`LICENSE` and `THIRD_PARTY_NOTICES.md`. External source files retain their own
copyright and license notices.

## Русский

DS4 Audio — экспериментальный проект под macOS с лицензией GPLv3-or-later для
передачи звука на Sony DualShock 4 через вендорный Bluetooth HID-аудиоканал.
Контроллер не определяется как обычное A2DP/HFP-аудиоустройство: звук
кодируется кадрами SBC и помещается в HID output reports.

### Что входит в проект

- `tools/ds4probe/` — консольный стример и зонд протокола Bluetooth.
- `tools/ds4driver/` — виртуальное аудиоустройство CoreAudio «DualShock 4» на
  основе vendored-библиотеки libASPL под MIT.
- Диагностические инструменты Bluetooth/HID/L2CAP и эксперименты с полосой
  пропускания в `tools/`.
- Вендоренная реализация SBC в `tools/ds4probe/Sources/CSBC/` с сохранёнными
  исходными уведомлениями LGPL-2.1-or-later.

SwiftUI-GUI поддерживается отдельно в ветке `gui-system-audio`.

### Требования

- macOS 13 или новее.
- Xcode Command Line Tools или Xcode с инструментами, совместимыми со Swift
  5.9.
- DualShock 4, сопряжённый по Bluetooth, для потоковой передачи.
- Права администратора для установки виртуального аудиодрайвера.

Тесты Bluetooth и аудиооборудования нужно запускать вне ограниченной или
песочницы среды.

### Сборка стримера

```bash
cd tools/ds4probe
swift build -c release
```

### Сборка и установка виртуального аудиодрайвера

```bash
cd tools/ds4driver
./build.sh
sudo ./install-driver.sh
```

Драйвер публикует временное устройство CoreAudio **DualShock 4**, пока
работает стример. Через него можно захватывать системный звук и кодировать
его для контроллера.

**Предупреждение:** установка изменяет системный каталог CoreAudio HAL,
требует подтверждения администратора и выполняется на ваш риск. Удаление:

```bash
cd tools/ds4driver
sudo ./uninstall-driver.sh
```

### Сопряжение контроллера

1. Отключите USB-кабель.
2. Удерживайте **Share + PS**, пока световая панель не начнёт мигать.
3. Откройте **Системные настройки → Bluetooth** и выберите **Wireless
   Controller**.
4. Убедитесь, что контроллер виден как Bluetooth HID-устройство.

Встроенный динамик по USB не работает. Если сопряжено несколько
контроллеров, задайте адрес для диагностических инструментов:

```bash
export DS4_ADDRESS='AA:BB:CC:DD:EE:FF'
./tools/reconnect/monitor 20
```

Адрес можно посмотреть в **Отчёте о системе → Bluetooth** или вывести через
инструменты проекта. Не публикуйте настоящий персональный Bluetooth-адрес.

### Запуск системного звука

```bash
cd tools/ds4probe
./ds4-system-audio.sh
```

Скрипт выбирает loopback-устройство «DualShock 4», использует осторожный
профиль SBC 16 кГц и возвращает прежний системный вывод после остановки.

### Архитектура и ограничения

```text
Приложения macOS
        ↓
CoreAudio loopback «DualShock 4»
        ↓
ds4probe: захват → ресемплинг → SBC → HID-репорты
        ↓
Динамик или выход на наушники DualShock 4 по Bluetooth
```

Профиль ограничен macOS Bluetooth HID-каналом и прошивкой контроллера,
поэтому качество и пропускная способность ниже обычного A2DP. Проект
экспериментальный и требует настоящего контроллера для проверки.

### Решение проблем

- **Контроллер не найден:** повторите сопряжение, отключите USB, разбудите
  контроллер кнопкой PS и проверьте Bluetooth. Для точечной диагностики
  задайте `DS4_ADDRESS`.
- **Нет звука:** установите HAL-драйвер, выполните `ds4probe --list-audio`,
  выберите **DualShock 4** системным выходом в loopback-режиме и убедитесь,
  что стример запущен. Остановите другие Bluetooth/HID-тесты.
- **Драйвер установлен, но устройства нет:** перезапустите стример —
  устройство публикуется только при активном heartbeat. После обновления
  macOS может потребоваться переустановка.
- **Звук прерывается:** используйте профиль по умолчанию 16 кГц/bitpool 12;
  Bluetooth HID в macOS заметно уже A2DP.

### Отказ от связи с Sony

Это независимый экспериментальный проект, **не связанный с Sony Interactive
Entertainment, Sony Corporation или PlayStation и не одобренный, не
спонсируемый и не поддерживаемый ими**. “DualShock 4” и знаки PlayStation
принадлежат их владельцам. Используйте программу на свой риск: она может
изменить маршрутизацию звука, установить системный драйвер или перестать
работать после обновления macOS.

### Лицензия

Код проекта распространяется под **GNU GPLv3 или любой более поздней
версией**. См. `LICENSE` и `THIRD_PARTY_NOTICES.md`. Внешние исходники
сохраняют собственные copyright-уведомления и условия лицензий.
