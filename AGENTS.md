# AGENTS.md

## Project overview

DS4 Audio is a macOS project that streams audio to the built-in speaker or
headphone output of a Sony DualShock 4 over Bluetooth HID reports. The public
`main` branch contains the shared low-level tools, vendored SBC encoder, and
CoreAudio HAL loopback driver. The SwiftUI GUI is developed separately on
`gui-system-audio` and is not present in `main`.

## Repository layout

- `tools/ds4probe/` — Swift command-line streamer and SBC integration.
- `tools/ds4driver/` — CoreAudio HAL driver and its vendored MIT-licensed
  libASPL dependency.
- `tools/ds4gui/` — SwiftUI application, maintained on the
  `gui-system-audio` branch rather than `main`.
- `tools/*` — macOS Bluetooth, HID, audio, and diagnostic utilities.
- `THIRD_PARTY_NOTICES.md` — external-code and license information.

Research snapshots, local artifacts, backups, and reference repositories are
not part of the public source tree. In particular, `/refs/` is intentionally
ignored because it contains external checkouts, binaries, and extracted files.
Test audio is generated or supplied locally and must not be committed.

## License and attribution

Project-owned code is released under GNU GPLv3 or later. Do not remove or
rewrite copyright and SPDX notices in vendored code. Before changing a
third-party file, read its local license and update `THIRD_PARTY_NOTICES.md`
if the dependency or its origin changes.

## Build requirements

- macOS 13 or newer.
- Xcode Command Line Tools or Xcode with Swift 5.9-compatible tooling.
- Bluetooth access and a paired DualShock 4 for hardware tests.
- Administrator access is required to install the CoreAudio HAL driver.

Run Bluetooth and hardware tests outside restricted/sandboxed environments.

## Common build commands

```bash
cd tools/ds4probe
swift build -c release

cd ../ds4driver
./build.sh
```

The GUI build and packaging scripts live under `tools/ds4gui/` on the
`gui-system-audio` branch.

## Testing and verification

There is no XCTest target in the current packages. Use these checks:

```bash
cd tools/ds4probe
swift build -c release
swift run ds4probe --help
swift run ds4probe --list-audio
```

For the GUI branch, build the universal app from the repository root:

```bash
./tools/ds4gui/build-app.sh
```

Hardware checks must run outside a sandbox with a paired controller. For
audio-file tests, set the input explicitly rather than committing test media:

```bash
export DS4_TEST_AUDIO=/absolute/path/to/test.wav
./tools/ds4probe/ds4-latency-test.sh
```

The latency scripts generate temporary tones under `/tmp`; recorded WAV/MP3
files, captures, logs, and other test audio stay local and are ignored.

## Branch rules

- Shared streamer, driver, protocol, and diagnostic changes go to `main`.
- GUI changes go to `gui-system-audio`.
- After changes land in `main`, update `gui-system-audio` by merging or
  rebasing `main` before releasing or continuing GUI work.
- Keep the GUI branch's README and the root README consistent when user-facing
  behavior changes.

## Documentation rules

The root `README.md` is bilingual: every user-facing section added or changed
in English must have a corresponding Russian section, with matching meaning
and heading structure. The GUI README follows the same rule.

## Changes and verification

- Keep generated files, `.app` bundles, build trees, caches, backups, and
  personal artifacts out of commits.
- Do not commit secrets, credentials, private keys, personal absolute paths,
  Bluetooth addresses tied to a personal device, or machine-specific logs.
- Run the narrowest relevant build or test after changes.
- Review `git diff --check`, the staged file list, and a secret/path scan before
  committing or pushing.
- Preserve existing third-party notices and document any ported code.
