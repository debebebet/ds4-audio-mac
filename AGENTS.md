# AGENTS.md

## Project overview

DS4 Audio is a macOS project that streams audio to the built-in speaker or
headphone output of a Sony DualShock 4 over Bluetooth HID reports. It contains
low-level diagnostic tools, a vendored SBC encoder, a CoreAudio HAL loopback
driver, and a SwiftUI GUI.

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

## Changes and verification

- Keep generated files, `.app` bundles, build trees, caches, backups, and
  personal artifacts out of commits.
- Do not commit secrets, credentials, private keys, personal absolute paths,
  Bluetooth addresses tied to a personal device, or machine-specific logs.
- Run the narrowest relevant build or test after changes.
- Review `git diff --check`, the staged file list, and a secret/path scan before
  committing or pushing.
- Preserve existing third-party notices and document any ported code.
