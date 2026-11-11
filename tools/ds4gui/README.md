# DualShock 4 Audio — GUI

## Important: first launch on macOS

The distributed application is not signed with an Apple Developer certificate
or notarized. macOS may therefore quarantine it after download. Clear the
quarantine attribute before opening the app:

```bash
xattr -cr "/path/to/DualShock 4 Audio.app"
open "/path/to/DualShock 4 Audio.app"
```

`xattr -cr` removes the quarantine metadata attached by macOS to downloaded
files; it does not install anything or bypass the app's own permissions.

## English

DualShock 4 Audio is a SwiftUI macOS front end for the `tools/ds4probe`
Bluetooth streamer and the virtual CoreAudio device from `tools/ds4driver`.
It routes system audio to a paired Sony DualShock 4 over the controller's
vendor-specific Bluetooth HID audio path.

### Features

- Automatically discovers Bluetooth DualShock 4 controllers.
- Streams all system audio through the virtual CoreAudio device named
  **DualShock 4**.
- Controls the controller speaker volume while streaming.
- Installs and updates the required HAL driver through a first-run setup wizard.
- Restores the previous system output when streaming stops or the app exits.
- Keeps the temporary CoreAudio device visible only while the app is running.
- Shows the `ds4probe` log and recovers from a dead audio-capture tap.

### Requirements

- macOS 13 or newer.
- A DualShock 4 paired over Bluetooth; USB does not stream to the built-in
  speaker.
- Administrator approval for the one-time HAL driver installation.
- Microphone permission may be requested because the virtual device is exposed
  to macOS as an audio input for loopback capture.

### Build

From the repository root:

```bash
cd tools/ds4gui
./build-app.sh
```

This builds universal arm64/x86_64 binaries and creates:

```text
tools/ds4gui/build/DualShock 4 Audio.app
```

For development without an app bundle:

```bash
cd tools/ds4gui
swift run DS4Audio
```

The app searches for `ds4probe` in `DS4PROBE_BIN`, the app's Resources,
the repository tree, and the current directory, in that order.

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

The HAL driver publishes the CoreAudio device while the GUI refreshes
`/var/tmp/com.ds4audio.gui.heartbeat`. If the app exits or crashes, the
heartbeat is removed or expires and the device disappears automatically.

### Limitations

The Bluetooth HID path is not A2DP/HFP and is constrained by macOS link
scheduling and DualShock 4 firmware. The default profile is 16 kHz SBC,
joint stereo, bitpool 12, report `0x16`; quality and throughput are therefore
lower than ordinary Bluetooth audio.

## Русский
SwiftUI-обвязка над проверенным стримером `tools/ds4probe`.

Что умеет:

- **Автоподхват контроллера** — скан HID-устройств раз в 5 секунд. Если DS4
  подключился по Bluetooth, приложение автоматически его находит; при
  включённом системном режиме сразу запускает поток, при отключении —
  останавливает и ждёт следующего подключения.
- **Громкость динамика DS4** — слайдер и пресеты. Во время стрима громкость
  меняется на лету: GUI пишет значение в файл, `ds4probe` переотправляет
  control-отчёт `0x11`, не прерывая аудио.
- **Системный звук** — переключатель, который делает звук всех приложений
  источником для динамика геймпада. Системное аудиоустройство при этом
  называется **«DualShock 4»**.
- **Первоначальная настройка** — при первом запуске открывается мастер:
  что нужно приложению, установка аудиодрайвера и проверка геймпада. Мастер
  можно открыть снова кнопкой «Настройка…».
- **Чистая система** — устройство «DualShock 4» появляется в списке
  CoreAudio только пока приложение работает, и исчезает после его закрытия.
- **Журнал** — вывод `ds4probe` и понятные сообщения об ошибках.

## Как устройство убирается из системы

HAL-драйвер остаётся установленным в `/Library/Audio/Plug-Ins/HAL`, но
устройство **«DualShock 4» видно только при запущенном приложении**.

Приложение обновляет файл-heartbeat `/var/tmp/com.ds4audio.gui.heartbeat`
раз в секунду. Драйвер следит за файлом: свежий — устройство опубликовано в
CoreAudio, протухший или удалённый — устройство убрано из списка. При выходе
приложение сначала возвращает прежний системный вывод, затем удаляет
heartbeat, и через доли секунды устройство исчезает из «Настроек звука».

Никаких запросов пароля при обычном запуске и выходе не нужно — пароль
спрашивается только при установке драйвера. Если приложение упало,
heartbeat протухнет сам через 4 секунды, и устройство тоже исчезнет.

## Первоначальная настройка

При первом запуске показывается мастер из четырёх шагов:

1. **Добро пожаловать** — что делает приложение и что требуется.
2. **Аудиодрайвер** — установка или обновление драйвера «DualShock 4»
   (нужен пароль администратора). Состояние определяется сравнением
   контрольной суммы установленного бинарника с тем, что лежит внутри
   приложения, поэтому «устаревшая» версия тоже предлагается к обновлению.
3. **Контроллер** — проверка, что DualShock 4 виден по Bluetooth.
4. **Готово** — итог и переход в основное окно.

Мастер можно открыть в любой момент кнопкой «Настройка…» в карточке
«Системный звук». Отметка о прохождении хранится в ключе
`ds4.setupCompleted`.

## Требования

- macOS 13+.
- DualShock 4, подключённый **по Bluetooth** (по USB звук в динамик не идёт).
- Драйвер «DualShock 4» из `tools/ds4driver` — устанавливается прямо из GUI
  (кнопка «Установить драйвер…», потребуется пароль администратора).
  BlackHole больше не нужен.

## Сборка и запуск

```bash
cd tools/ds4gui
./run.sh
```

`run.sh` соберёт драйвер, `ds4probe` и GUI, сложит `.app` в
`tools/ds4gui/build/DualShock 4 Audio.app` и откроет его.

Можно отдельно:

```bash
./build-app.sh
open "build/DualShock 4 Audio.app"
```

`build-app.sh` собирает **universal**-бинарники (arm64 + x86_64) для macOS 13+:
драйвер — через `clang++ -arch arm64 -arch x86_64`, GUI и `ds4probe` — через два
кросс-сборочных `swift build --triple`, затем `lipo -create`. Готовый бандл
подписывается ad-hoc (`codesign --force --deep --sign -`); для распространения
нужна Developer ID-подпись и нотаризация.

Проверить архитектуры:

```bash
lipo -info "build/DualShock 4 Audio.app/Contents/MacOS/DS4Audio"
lipo -info "build/DualShock 4 Audio.app/Contents/Resources/ds4probe"
lipo -info "build/DualShock 4 Audio.app/Contents/Resources/DS4AudioDriver.driver/Contents/MacOS/DS4AudioDriver"
codesign --verify --deep --strict "build/DualShock 4 Audio.app"
```

Для разработки без .app-бандла:

```bash
cd tools/ds4gui
swift run DS4Audio
```

GUI ищет `ds4probe` в таком порядке: переменная `DS4PROBE_BIN`, Resources
внутри .app, дерево проекта, текущая папка.

## Как устроен системный режим

DS4 не регистрирует в macOS стандартный аудиопрофиль, поэтому звук идёт через
собственный виртуальный HAL-драйвер «DualShock 4» (папка `tools/ds4driver`):

```
любое приложение
      ↓
«DualShock 4» (виртуальное устройство CoreAudio)
      ↓
loopback-буфер драйвера
      ↓
ds4probe: ресемплинг 16 кГц → SBC joint stereo, bitpool 12
      ↓
Bluetooth HID (report 0x11 + 0x16)
      ↓
динамик DualShock 4
```

Драйвер устанавливается один раз и отображается в «Настройках звука» как
**DualShock 4**. GUI запоминает прежний вывод системы, переключается на
«DualShock 4» при включении режима и возвращает прежнее устройство при
выключении/выходе. BlackHole и агрегатные устройства не используются.

Громкость по умолчанию — `0x18` (30 % от аппаратного максимума `0x4F`),
как в рабочем профиле проекта. Профиль потока: 16 кГц, joint stereo,
bitpool 12, report `0x16`, 10 кадров (105 % реалтайма).

## Автоподхват

`ControllerScanner` раз в 5 секунд перечисляет HID-устройства и ищет
`VID 054C`, `PID 05C4/09CC`. Если найден Bluetooth-экземпляр:

- при включённом системном режиме запускается поток;
- при выключенном — просто показывается статус «подключён».

USB-подключение определяется, но помечается предупреждением: звук в
встроенный динамик по USB не идёт.

На каждый скан создаётся **свежий** `IOHIDManager`. Постоянный менеджер без
`IOHIDManagerScheduleWithRunLoop` не получает уведомлений о подключении, и его
список устройств замораживается в момент открытия — геймпад, включённый уже
после запуска приложения, тогда не виден никогда. Пересоздание менеджера на
каждом тике — это то, что делает `ds4probe --list`.

## Смена системного вывода на лету

Если системный вывод переключить с «DualShock 4» на другое устройство и
обратно, macOS пересоздаёт входной audio unit устройства, и tap захвата при
этом молча умирает: колбэки перестают приходить, а стример продолжает слать в
контроллер тишину. Без обработки этого «поток активен», а звука нет.

`ds4probe` следит за живостью tap'а (по времени последнего колбэка) и сам
пересоздаёт его, когда он умер. В журнале это видно:

```
[capture] tap перестал приходить (смена вывода?) — пересоздаём…
[capture] tap пересоздан, захват восстановлен
```

В строке `[latency]` дополнительно печатается состояние tap'а — `tap жив` или
`tap МЁРТВ`.

## Ограничения

- Нужен установленный HAL-драйвер «DualShock 4» — GUI ставит его сам, но
  требуется пароль администратора. После обновления macOS драйвер может
  понадобиться переустановить.
- Качество ограничено профилем: 16 кГц, SBC bitpool 12 (полоса ~8 кГц).
- Потолок канала macOS ≈ 5 КБ/с; профиль использует ~4.6 КБ/с, поэтому
  возможны редкие прерывания — это ограничение стека, а не GUI.
- При первом захвате системного звука macOS может запросить разрешение на
  использование микрофона (виртуальное устройство выглядит как аудиовход).
