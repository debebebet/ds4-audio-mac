#!/usr/bin/env python3
"""Извлечение целочисленных констант из тел методов по метаданным REA.

Вход:
  1) JSON-выгрузка `rea inspect-managed-members` (normalized_result.methods)
  2) путь к сборке PE/CLI

REA отдаёт для каждого метода file_offset тела CIL, il_size и il_sha256.
Мы читаем CIL-поток по этому смещению и выписываем все литералы (ldc.i4*,
ldc.i8, ldstr), привязывая их к evidence_id и sha256 сборки.

Это даёт независимое подтверждение констант протокола ПО ШИПНОМУ БИНАРНИКУ,
а не по исходникам.

Использование:
  python3 tools/cill-literals.py <rea_members.json> <assembly.dll> [подстрока_типа]
"""
import json
import struct
import sys


def decode_7bit_len(buf, pos):
    result = 0
    shift = 0
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7


def scan_il(il):
    """Возвращает список литералов, найденных в CIL-потоке."""
    out = []
    pos = 0
    n = len(il)

    def need(k):
        return pos + k <= n

    while pos < n:
        op = il[pos]
        start = pos
        pos += 1
        try:
            if op == 0x20:  # ldc.i4 (int32)
                val = struct.unpack_from("<i", il, pos)[0]; pos += 4
                out.append((start, "ldc.i4", val))
            elif op == 0x21:  # ldc.i4.s (int8)
                val = struct.unpack_from("<b", il, pos)[0]; pos += 1
                out.append((start, "ldc.i4.s", val))
            elif op == 0x22:  # ldc.i4 (int64)
                val = struct.unpack_from("<q", il, pos)[0]; pos += 8
                out.append((start, "ldc.i4.l", val))
            elif op == 0x1F:  # ldc.i4.s (byte-формой, отрицательное)
                val = struct.unpack_from("<b", il, pos)[0]; pos += 1
                out.append((start, "ldc.i4.s", val))
            elif op == 0xFE and pos < n and il[pos] == 0x0E:  # ldc.i8
                pos += 1
                val = struct.unpack_from("<q", il, pos)[0]; pos += 8
                out.append((start, "ldc.i8", val))
            elif op == 0x1E:  # ldc.i8
                val = struct.unpack_from("<q", il, pos)[0]; pos += 8
                out.append((start, "ldc.i8", val))
            elif op == 0x72:  # ldstr
                token = struct.unpack_from("<I", il, pos)[0]; pos += 4
                out.append((start, "ldstr", f"token 0x{token:08X}"))
            elif op in (0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x1A, 0x1B):
                pos += 1
            elif op in (0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
                        0x0B, 0x0C, 0x0D, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1C, 0x1D):
                pos += 2
            elif op in (0x28, 0x6F, 0x73, 0x27, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F,
                        0x80, 0x81, 0x8C, 0x8D, 0x74, 0x75, 0x79, 0xA5, 0x70,
                        0x71, 0x8F, 0xA3, 0xA4, 0xC2, 0xC6, 0xD0):
                pos += 4
            elif op == 0x45:  # switch
                count = struct.unpack_from("<I", il, pos)[0]
                pos += 4 + 4 * count
            elif op == 0xFE:
                pos += 1
            elif 0x38 <= op <= 0x44 or 0x46 <= op <= 0x6E:
                pos += 4  # br / brfalse / ... (int32 target)
            # прочие опкоды операндов не имеют
        except (struct.error, IndexError):
            break
    return out


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    meta_path, dll_path = sys.argv[1], sys.argv[2]
    filt = sys.argv[3] if len(sys.argv) > 3 else ""

    meta = json.load(open(meta_path))
    evidence_id = meta.get("evidence_id", "?")
    res = meta.get("normalized_result", {})
    subject = meta.get("subject", {})
    digest = subject.get("digest", {}).get("sha256", "?")
    print(f"# REA evidence_id : {evidence_id}")
    print(f"# assembly sha256 : {digest}")
    print(f"# assembly        : {dll_path}")
    print()

    with open(dll_path, "rb") as fh:
        blob = fh.read()

    methods = res.get("methods", [])
    rows = []
    for m in methods:
        dtype = m.get("declaring_type", "")
        name = m.get("name", "")
        body = m.get("body") or {}
        if body.get("status") != "present":
            continue
        off = body.get("file_offset")
        size = body.get("il_size")
        if off is None or size is None:
            continue
        if filt and filt.lower() not in dtype.lower() and filt.lower() not in name.lower():
            continue
        rows.append((dtype, name, off, size, body.get("il_sha256", "")))

    for dtype, name, off, size, ilhash in rows:
        il = blob[off:off + size]
        lits = scan_il(il)
        interesting = [l for l in lits if isinstance(l[2], int)]
        uniq = []
        for _, op, val in interesting:
            if val not in [u[1] for u in uniq]:
                uniq.append((op, val))
        if not uniq:
            continue
        print(f"## {dtype}.{name}")
        print(f"   body@file_offset={off} il_size={size} il_sha256={ilhash[:16]}…")
        print("   literals:", ", ".join(f"{op}={val}" for op, val in uniq))
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
