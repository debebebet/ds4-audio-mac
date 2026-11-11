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

### Лицензия

Код проекта распространяется под **GNU GPLv3 или любой более поздней
версией**. См. `LICENSE` и `THIRD_PARTY_NOTICES.md`. Внешние исходники
сохраняют собственные copyright-уведомления и условия лицензий.
