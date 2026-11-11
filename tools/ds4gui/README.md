# DualShock 4 Audio — GUI

[English](#english) | [Русский](#русский)

## Important: first launch on macOS

The distributed application is not signed with an Apple Developer certificate
or notarized. Before opening a downloaded copy, remove macOS quarantine
metadata:

```bash
xattr -cr "/path/to/DualShock 4 Audio.app"
open "/path/to/DualShock 4 Audio.app"
```

This removes the quarantine attribute only; it does not install the app or
change its permissions. A ready universal build is published on the [GitHub
Releases page](https://github.com/debebebet/ds4-audio-mac/releases/latest).

## English

DualShock 4 Audio is a SwiftUI macOS front end for the `tools/ds4probe`
Bluetooth streamer and the virtual CoreAudio device from `tools/ds4driver`.
It routes system audio to a paired Sony DualShock 4 over the controller's
vendor-specific Bluetooth HID audio path.

### Features

- Discovers Bluetooth DualShock 4 controllers automatically.
- Routes system audio through the virtual CoreAudio device **DualShock 4**.
- Changes controller speaker volume while streaming.
- Provides a first-run setup wizard and status/log messages.
- Restores the previous system output when streaming stops or the app exits.
- Removes the temporary CoreAudio device after the app stops.

### Requirements and warnings

- macOS 13 or newer.
- A DualShock 4 paired over Bluetooth; USB does not stream to the built-in
  speaker.
- The HAL driver is installed into the system CoreAudio directory and requires
  administrator authentication. Review the source before approving it.
- Microphone permission may be requested because the virtual loopback device is
  exposed to macOS as an audio input.

### Build and run

From the repository root:

```bash
cd tools/ds4gui
./build-app.sh
```

This creates a universal app:

```text
tools/ds4gui/build/DualShock 4 Audio.app
```

For development without an app bundle:

```bash
cd tools/ds4gui
swift run DS4Audio
```

### Install and remove the driver

The GUI can install or update the driver from the setup wizard and will ask for
an administrator password. To remove it manually:

```bash
cd tools/ds4driver
sudo ./uninstall-driver.sh
```

Removing the driver disables the virtual **DualShock 4** CoreAudio device; it
does not unpair the controller.

### Runtime model

```text
macOS applications
        ↓
CoreAudio “DualShock 4” loopback device
        ↓
GUI → ds4probe: capture → resample → SBC → HID reports
        ↓
DualShock 4 speaker or headphone output
```

The driver publishes the device while the GUI refreshes
`/var/tmp/com.ds4audio.gui.heartbeat`. If the app exits or crashes, the
heartbeat is removed or expires and the device disappears automatically.

### Troubleshooting

- **Controller not found:** disconnect USB, wake the controller with PS, verify
  Bluetooth pairing, and stop other HID test tools.
- **No sound:** confirm the driver is installed, run `ds4probe --list-audio`,
  select **DualShock 4** as the system output, and check the GUI log.
- **No CoreAudio device:** restart the GUI; after a macOS update, reinstall
  the driver from the setup wizard.
- **Intermittent sound:** use the default 16 kHz/bitpool 12 profile; the
  macOS Bluetooth HID link has less bandwidth than A2DP.

### Limitations and disclaimer

The Bluetooth HID path is not A2DP/HFP and depends on macOS link scheduling and
DualShock 4 firmware. This is an independent experimental project, not
affiliated with, endorsed by, sponsored by, or approved by Sony Interactive
Entertainment, Sony Corporation, or PlayStation. “DualShock 4” and PlayStation
marks belong to their respective owners. Use the software at your own risk.

## Русский

DualShock 4 Audio — приложение SwiftUI для macOS, использующее Bluetooth-
стример `tools/ds4probe` и виртуальное CoreAudio-устройство из
`tools/ds4driver`. Оно передаёт системный звук на сопряжённый Sony DualShock 4
через вендорный Bluetooth HID-аудиоканал контроллера.

### Возможности

- Автоматически находит DualShock 4 по Bluetooth.
- Передаёт системный звук через виртуальное устройство CoreAudio **DualShock 4**.
- Позволяет менять громкость динамика контроллера во время стрима.
- Показывает мастер настройки, состояние и журнал.
- Возвращает прежний системный вывод после остановки или выхода.
- Убирает временное CoreAudio-устройство после остановки приложения.

### Требования и предупреждения

- macOS 13 или новее.
- DualShock 4, сопряжённый по Bluetooth; по USB встроенный динамик не работает.
- HAL-драйвер устанавливается в системный каталог CoreAudio и требует
  подтверждения администратора. Перед подтверждением изучите исходный код.
- macOS может запросить доступ к микрофону: виртуальный loopback представлен
  системе как аудиовход.

### Сборка и запуск

Из корня репозитория:

```bash
cd tools/ds4gui
./build-app.sh
```

Будет создано универсальное приложение:

```text
tools/ds4gui/build/DualShock 4 Audio.app
```

Для разработки без app-бандла:

```bash
cd tools/ds4gui
swift run DS4Audio
```

### Установка и удаление драйвера

GUI устанавливает или обновляет драйвер через мастер первоначальной настройки
и запрашивает пароль администратора. Удалить драйвер вручную:

```bash
cd tools/ds4driver
sudo ./uninstall-driver.sh
```

После удаления виртуальное устройство **DualShock 4** исчезнет из CoreAudio;
сопряжение контроллера при этом не удаляется.

### Как работает приложение

```text
Приложения macOS
        ↓
CoreAudio loopback «DualShock 4»
        ↓
GUI → ds4probe: захват → ресемплинг → SBC → HID-репорты
        ↓
Динамик или выход на наушники DualShock 4
```

Драйвер публикует устройство, пока GUI обновляет
`/var/tmp/com.ds4audio.gui.heartbeat`. При выходе или сбое heartbeat удаляется
или протухает, и устройство исчезает автоматически.

### Решение проблем

- **Контроллер не найден:** отключите USB, разбудите контроллер кнопкой PS,
  проверьте сопряжение Bluetooth и остановите другие HID-тесты.
- **Нет звука:** проверьте установку драйвера, выполните
  `ds4probe --list-audio`, выберите **DualShock 4** системным выходом и изучите
  журнал GUI.
- **Нет CoreAudio-устройства:** перезапустите GUI; после обновления macOS
  переустановите драйвер через мастер.
- **Звук прерывается:** используйте профиль 16 кГц/bitpool 12; Bluetooth HID в
  macOS имеет меньшую пропускную способность, чем A2DP.

### Ограничения и отказ от связи с Sony

Bluetooth HID — не A2DP/HFP; работа зависит от планировщика macOS и прошивки
DualShock 4. Это независимый экспериментальный проект, **не связанный с Sony
Interactive Entertainment, Sony Corporation или PlayStation и не одобренный,
не спонсируемый и не поддерживаемый ими**. “DualShock 4” и знаки PlayStation
принадлежат их владельцам. Используйте программу на свой риск.
