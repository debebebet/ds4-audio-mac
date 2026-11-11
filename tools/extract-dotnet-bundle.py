#!/usr/bin/env python3
"""Извлечение сборок из .NET single-file bundle (формат hostfxr BundleMarker).

Сигнатура bundle — 32 байта:
    8b 12 02 b9 6a 61 20 38 72 7b 93 02 14 d7 a0 32
    13 f5 b9 e6 ef ae 33 18 ee 3b 2d ce 24 b3 6a ae
За ней (перед ней) — 8-байтовый смещение начала bundle header.
"""
import os
import struct
import sys

BUNDLE_SIGNATURE = bytes([
    0x8b, 0x12, 0x02, 0xb9, 0x6a, 0x61, 0x20, 0x38,
    0x72, 0x7b, 0x93, 0x02, 0x14, 0xd7, 0xa0, 0x32,
    0x13, 0xf5, 0xb9, 0xe6, 0xef, 0xae, 0x33, 0x18,
    0xee, 0x3b, 0x2d, 0xce, 0x24, 0xb3, 0x6a, 0xae,
])


def read_7bit_int(buf, pos):
    """Кодирование длины строк .NET (7-bit encoded int)."""
    result = 0
    shift = 0
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7


def extract(path, out_dir):
    with open(path, "rb") as fh:
        data = fh.read()

    # BundleMarker: 32 байта подписи; int64-смещение заголовка лежит ПЕРЕД подписью.
    sig_pos = data.rfind(BUNDLE_SIGNATURE)
    if sig_pos < 0:
        print("ERROR: bundle signature not found — это не .NET single-file bundle")
        return 1

    header_offset = struct.unpack_from("<q", data, sig_pos - 8)[0]
    if header_offset <= 0 or header_offset >= len(data):
        print(f"ERROR: неверное смещение header: {header_offset}")
        return 1

    pos = header_offset
    major, minor = struct.unpack_from("<ii", data, pos)
    pos += 8
    file_count = struct.unpack_from("<i", data, pos)[0]
    pos += 4

    bundle_id_len, pos = read_7bit_int(data, pos)
    bundle_id = data[pos:pos + bundle_id_len].decode("utf-8", "replace")
    pos += bundle_id_len

    print(f"bundle header @ {header_offset}: v{major}.{minor}, files={file_count}, id={bundle_id}")

    if major >= 2:
        # deps.json / runtimeconfig.json offsets+sizes, flags
        for _ in range(2):
            struct.unpack_from("<qq", data, pos)
            pos += 16
        pos += 8  # flags (uint64)

    os.makedirs(out_dir, exist_ok=True)
    extracted = []
    for i in range(file_count):
        offset, size = struct.unpack_from("<qq", data, pos)
        pos += 16
        compressed_size = 0
        if major >= 6:
            compressed_size = struct.unpack_from("<q", data, pos)[0]
            pos += 8
        file_type = data[pos]
        pos += 1
        name_len, pos = read_7bit_int(data, pos)
        name = data[pos:pos + name_len].decode("utf-8", "replace")
        pos += name_len

        stored_size = compressed_size if compressed_size else size
        blob = data[offset:offset + stored_size]

        if compressed_size:
            import zlib
            try:
                blob = zlib.decompress(blob, -15)
            except zlib.error:
                try:
                    blob = zlib.decompress(blob)
                except zlib.error:
                    pass

        safe = name.replace("\\", "/").lstrip("/")
        dest = os.path.join(out_dir, safe)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as out:
            out.write(blob)
        extracted.append((name, file_type, len(blob)))

    print(f"извлечено {len(extracted)} файлов в {out_dir}")
    for name, ftype, size in extracted:
        kind = {0: "Unknown", 1: "Assembly", 2: "NativeBinary", 3: "DepsJson",
                4: "RuntimeConfigJson", 5: "Symbols"}.get(ftype, f"Type{ftype}")
        print(f"  [{kind:>16}] {size:>10} B  {name}")
    return 0


if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else "DS4SoundLink_v2.0.2.exe"
    dst = sys.argv[2] if len(sys.argv) > 2 else "extract"
    sys.exit(extract(src, dst))
