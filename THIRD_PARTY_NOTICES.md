# Third-party notices

This project is distributed under **GNU GPLv3 or later** for the project-owned
code. The components below retain their own copyright and license terms.

## SBC codec (`tools/ds4probe/Sources/CSBC`)

The vendored SBC implementation is based on the BlueZ/libsbc codebase. The
source files retain their original copyright notices and are marked
`LGPL-2.1-or-later`. The project adds a small `sbc_configure()` extension and
an arm64 portability guard; those changes are project modifications.

Originals:

- BlueZ SBC: <https://git.kernel.org/pub/scm/bluetooth/sbc.git>
- nefarius/libsbc fork used for comparison: <https://github.com/nefarius/libsbc>

The LGPL-2.1-or-later terms for these source files are compatible with this
GPLv3-or-later project. The `src/` command-line utilities in the reference
repository may have different GPL-2.0-or-later terms; they are not included
here.

## DS4AudioStreamer protocol reference

The project documentation and comments use `DS4AudioStreamer` as a protocol
and implementation reference. No `/refs/` checkout is required to build or
run this project.

- Original: <https://github.com/nefarius/DS4AudioStreamer>
- License: MIT, Copyright (c) 2025 Benjamin Höglinger-Stelzer

Any source originally copied from that project must retain its original MIT
notice. The current tree has no vendored copy of its repository; the
relationship is limited to protocol/format research and compatibility
references.

The original repository itself contains additional third-party components
under their own terms. Those components are not copied into this repository.

## DS4-Sound-Link research reference

Protocol comments also refer to the Windows DS4-Sound-Link implementation as
a research reference. Its source is not included in this repository.

- Original: <https://github.com/abh1shekbana/DS4-Sound-Link>
- License: MIT, Copyright (c) 2026 ControllerAudioSwitcher Contributors

## libASPL

The CoreAudio HAL driver vendors libASPL under
`tools/ds4driver/vendor/libASPL/`.

- Original: <https://github.com/gavv/libASPL>
- License: MIT, Copyright (c) Victor Gaydov and contributors
- Local license: `tools/ds4driver/vendor/libASPL/LICENSE`

## Other external code

Other third-party notices are kept next to the corresponding vendor source,
including the libASPL license above and the copyright/SPDX notices in the
vendored SBC files.
