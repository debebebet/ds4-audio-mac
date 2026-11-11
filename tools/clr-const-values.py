#!/usr/bin/env python3
"""Значения const-полей PE/CLI-сборки (таблица Constant метаданных).

REA (`inspect-managed-members`) даёт инвентарь полей, но без значений констант.
Этот инструмент читает таблицу Constant из того же файла, чей sha256
подтверждён REA, и печатает имя поля → значение.

Использование:
  python3 tools/clr-const-values.py <assembly.dll> [подстрока_имени]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from clrmeta import Metadata  # noqa: E402


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    dll_path = sys.argv[1]
    filt = sys.argv[2].lower() if len(sys.argv) > 2 else ""

    md = Metadata(dll_path)
    print(f"# assembly : {dll_path}")
    print(f"# tables   : {len(md.counts)}")
    print()
    for name, ctype, raw in md.const_values():
        if filt and filt not in name.lower():
            continue
        value, kind = md.decode_const(ctype, raw)
        extra = ""
        if isinstance(value, int) and kind in ("i4", "u4", "u1", "u2", "i2", "i1"):
            extra = f"  (0x{value & 0xFFFFFFFF:X})"
        print(f"  {name:<44} = {value}  [{kind}]{extra}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
