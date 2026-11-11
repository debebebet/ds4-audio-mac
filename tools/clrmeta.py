#!/usr/bin/env python3
"""Чтение метаданных PE/CLI: таблицы, const-поля, строки.

Реализация подмножества ECMA-335, достаточного для чтения таблицы Constant
(значения const-полей) и #Strings/#Blob.

Ключевая часть — корректный расчёт размеров строк таблиц: от него зависят
смещения всех последующих таблиц. Размер coded index зависит от числа строк
в ссылочных таблицах, поэтому считается в два прохода.
"""
import struct

# Номера таблиц (ECMA-335 II.22)
T_MODULE = 0x00
T_TYPEREF = 0x01
T_TYPEDEF = 0x02
T_FIELD_PTR = 0x03
T_FIELD = 0x04
T_METHOD_PTR = 0x05
T_METHODDEF = 0x06
T_PARAM_PTR = 0x07
T_PARAM = 0x08
T_INTERFACEIMPL = 0x09
T_MEMBERREF = 0x0A
T_CONSTANT = 0x0B
T_CUSTOMATTRIBUTE = 0x0C
T_FIELDMARSHAL = 0x0D
T_DECLSECURITY = 0x0E
T_CLASSLAYOUT = 0x0F
T_FIELDLAYOUT = 0x10
T_STANDALONESIG = 0x11
T_EVENTMAP = 0x12
T_EVENT_PTR = 0x13
T_EVENT = 0x14
T_PROPERTYMAP = 0x15
T_PROPERTY_PTR = 0x16
T_PROPERTY = 0x17
T_METHODSEMANTICS = 0x18
T_METHODIMPL = 0x19
T_MODULEREF = 0x1A
T_TYPESPEC = 0x1B
T_IMPLMAP = 0x1C
T_FIELDRVA = 0x1D
T_ENCLOG = 0x1E
T_ENCMAP = 0x1F
T_ASSEMBLY = 0x20
T_ASSEMBLYPROC = 0x21
T_ASSEMBLYREF = 0x23
T_FILE = 0x26
T_EXPORTEDTYPE = 0x27
T_MANIFESTRESOURCE = 0x28
T_NESTEDCLASS = 0x29
T_GENERICPARAM = 0x2A
T_METHODSPEC = 0x2B
T_GENERICPARAMCONSTRAINT = 0x2C

# Coded index: (таблицы, число бит тега)
CODED_INDEXES = {
    "TypeDefOrRef": ([T_TYPEDEF, T_TYPEREF, T_TYPESPEC], 2),
    "HasConstant": ([T_FIELD, T_PARAM, T_PROPERTY], 2),
    "HasCustomAttribute": (
        [T_METHODDEF, T_FIELD, T_TYPEREF, T_TYPEDEF, T_PARAM, T_INTERFACEIMPL,
         T_MEMBERREF, T_MODULE, T_PERMISSIONSET if False else T_DECLSECURITY,
         T_PROPERTY, T_EVENT, T_STANDALONESIG, T_MODULEREF, T_TYPESPEC,
         T_ASSEMBLY, T_ASSEMBLYREF, T_FILE, T_EXPORTEDTYPE, T_MANIFESTRESOURCE,
         T_GENERICPARAM, T_GENERICPARAMCONSTRAINT, T_METHODSPEC], 5),
    "HasFieldMarshal": ([T_FIELD, T_PARAM], 1),
    "HasDeclSecurity": ([T_TYPEDEF, T_METHODDEF, T_ASSEMBLY], 2),
    "MemberRefParent": ([T_TYPEDEF, T_TYPEREF, T_MODULEREF, T_METHODDEF,
                         T_TYPESPEC], 3),
    "HasSemantics": ([T_EVENT, T_PROPERTY], 1),
    "MethodDefOrRef": ([T_METHODDEF, T_MEMBERREF], 1),
    "MemberForwarded": ([T_FIELD, T_METHODDEF], 1),
    "Implementation": ([T_FILE, T_ASSEMBLYREF, T_EXPORTEDTYPE], 2),
    "CustomAttributeType": ([None, None, T_METHODDEF, T_MEMBERREF, None], 3),
    "ResolutionScope": ([T_MODULE, T_MODULEREF, T_ASSEMBLYREF, T_TYPEREF], 2),
    "TypeOrMethodDef": ([T_TYPEDEF, T_METHODDEF], 1),
}


def _idx_size(tables, counts, wide):
    """Размер индекса простой таблицы (2 или 4 байта)."""
    rows = max([counts.get(t, 0) for t in tables if t is not None] + [0])
    return 4 if (wide or rows >= 0x10000) else 2


def _coded_size(name, counts, wide):
    tables, tag_bits = CODED_INDEXES[name]
    rows = max([counts.get(t, 0) for t in tables if t is not None] + [0])
    return 4 if (wide or rows >= (1 << (16 - tag_bits))) else 2


def table_row_sizes(counts, heap_sizes):
    """Возвращает {table: размер строки} для всех таблиц, присутствующих в сборке."""
    str_w = bool(heap_sizes & 1)
    guid_w = bool(heap_sizes & 2)
    blob_w = bool(heap_sizes & 4)

    def S(name):
        return _coded_size(name, counts, False)

    def IDX(tables):
        return _idx_size(tables, counts, False)

    sizes = {
        T_MODULE: 2 + _idx_size([T_MODULE], counts, str_w) + 3 * _idx_size([T_MODULE], counts, guid_w),
        T_TYPEREF: S("ResolutionScope") + 2 * _idx_size([T_TYPEREF], counts, str_w),
        T_TYPEDEF: 4 + 2 * _idx_size([T_TYPEDEF], counts, str_w) + S("TypeDefOrRef")
                   + IDX([T_FIELD]) + IDX([T_METHODDEF]),
        T_FIELD_PTR: IDX([T_FIELD]),
        T_FIELD: 2 + _idx_size([T_FIELD], counts, str_w) + _idx_size([T_FIELD], counts, blob_w),
        T_METHOD_PTR: IDX([T_METHODDEF]),
        T_METHODDEF: 8 + 2 * _idx_size([T_METHODDEF], counts, str_w) + IDX([T_PARAM]),
        T_PARAM_PTR: IDX([T_PARAM]),
        T_PARAM: 4 + _idx_size([T_PARAM], counts, str_w),
        T_INTERFACEIMPL: IDX([T_TYPEDEF]) + S("TypeDefOrRef"),
        T_MEMBERREF: S("MemberRefParent") + _idx_size([T_MEMBERREF], counts, str_w)
                     + _idx_size([T_MEMBERREF], counts, blob_w),
        T_CONSTANT: 2 + S("HasConstant") + _idx_size([T_CONSTANT], counts, blob_w),
        T_CUSTOMATTRIBUTE: S("HasCustomAttribute") + S("CustomAttributeType")
                           + _idx_size([T_CUSTOMATTRIBUTE], counts, blob_w),
        T_FIELDMARSHAL: S("HasFieldMarshal") + _idx_size([T_FIELDMARSHAL], counts, blob_w),
        T_DECLSECURITY: 2 + S("HasDeclSecurity") + _idx_size([T_DECLSECURITY], counts, blob_w),
        T_CLASSLAYOUT: 2 + 4 + IDX([T_TYPEDEF]),
        T_FIELDLAYOUT: 4 + IDX([T_FIELD]),
        T_STANDALONESIG: _idx_size([T_STANDALONESIG], counts, blob_w),
        T_EVENTMAP: IDX([T_TYPEDEF]) + IDX([T_EVENT]),
        T_EVENT_PTR: IDX([T_EVENT]),
        T_EVENT: 2 + _idx_size([T_EVENT], counts, str_w) + S("TypeDefOrRef"),
        T_PROPERTYMAP: IDX([T_TYPEDEF]) + IDX([T_PROPERTY]),
        T_PROPERTY_PTR: IDX([T_PROPERTY]),
        T_PROPERTY: 2 + _idx_size([T_PROPERTY], counts, str_w) + _idx_size([T_PROPERTY], counts, blob_w),
        T_METHODSEMANTICS: 2 + IDX([T_METHODDEF]) + S("HasSemantics"),
        T_METHODIMPL: IDX([T_TYPEDEF]) + 2 * S("MethodDefOrRef"),
        T_MODULEREF: _idx_size([T_MODULEREF], counts, str_w),
        T_TYPESPEC: _idx_size([T_TYPESPEC], counts, blob_w),
        T_IMPLMAP: 2 + S("MemberForwarded") + _idx_size([T_IMPLMAP], counts, str_w) + IDX([T_MODULEREF]),
        T_FIELDRVA: 4 + IDX([T_FIELD]),
        T_ENCLOG: 4 + 4,
        T_ENCMAP: 4,
        T_ASSEMBLY: 4 + 2 * 4 + 4 + blob_w + str_w + str_w,
        T_ASSEMBLYPROC: 4,
        T_ASSEMBLYREF: 2 * 4 + 4 * blob_w + 4 + blob_w + str_w + str_w + blob_w,
        T_FILE: 4 + str_w + blob_w,
        T_EXPORTEDTYPE: 4 + 4 + str_w + str_w + S("Implementation"),
        T_MANIFESTRESOURCE: 4 + 4 + str_w + S("Implementation"),
        T_NESTEDCLASS: IDX([T_TYPEDEF]) + IDX([T_TYPEDEF]),
        T_GENERICPARAM: 2 + 2 + S("TypeOrMethodDef") + str_w,
        T_METHODSPEC: S("MethodDefOrRef") + blob_w,
        T_GENERICPARAMCONSTRAINT: IDX([T_TYPEDEF]) + S("TypeDefOrRef"),
    }
    return sizes


class Metadata:
    """Разобранные метаданные сборки PE/CLI."""

    def __init__(self, path):
        self.blob = open(path, "rb").read()
        self.streams = self._parse_root()
        key = "#~" if "#~" in self.streams else "#-"
        self.tables_off, self.tables_size = self.streams[key]
        self.counts, self.heap_sizes = self._parse_tables_header()
        self.sizes = table_row_sizes(self.counts, self.heap_sizes)
        self.table_offsets = self._compute_table_offsets()
        self.strings = self._stream("#Strings")
        self.blobs = self._stream("#Blob")

    # --- служебное ---

    def _stream(self, name):
        off, size = self.streams[name]
        return self.blob[off:off + size]

    def _parse_root(self):
        blob = self.blob
        pe_off = struct.unpack_from("<I", blob, 0x3C)[0]
        if blob[pe_off:pe_off + 4] != b"PE\0\0":
            raise ValueError("не PE-файл")
        coff = pe_off + 4
        num_sections = struct.unpack_from("<H", blob, coff + 2)[0]
        opt_size = struct.unpack_from("<H", blob, coff + 16)[0]
        opt = coff + 20
        magic = struct.unpack_from("<H", blob, opt)[0]
        dd_off = opt + (112 if magic == 0x20B else 96)
        cli_rva = struct.unpack_from("<I", blob, dd_off + 14 * 8)[0]
        if not cli_rva:
            raise ValueError("нет CLI header (не .NET сборка)")

        sections = []
        sec_off = opt + opt_size
        for i in range(num_sections):
            base = sec_off + i * 40
            vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", blob, base + 8)
            sections.append((vaddr, vsize, rawptr, rawsize))

        def rva_to_off(rva):
            for vaddr, vsize, rawptr, rawsize in sections:
                if vaddr <= rva < vaddr + max(vsize, rawsize):
                    return rawptr + (rva - vaddr)
            raise ValueError(f"RVA {rva:#x} вне секций")

        cli_off = rva_to_off(cli_rva)
        md_rva = struct.unpack_from("<I", blob, cli_off + 8)[0]
        md_off = rva_to_off(md_rva)

        pos = md_off + 12
        version_len = struct.unpack_from("<I", blob, pos)[0]
        pos += 4 + version_len
        pos = (pos + 3) & ~3
        pos += 2                                     # Flags
        num_streams = struct.unpack_from("<H", blob, pos)[0]
        pos += 2
        streams = {}
        for _ in range(num_streams):
            s_off, s_size = struct.unpack_from("<II", blob, pos)
            pos += 8
            name = b""
            while blob[pos] != 0:
                name += bytes([blob[pos]])
                pos += 1
            pos += 1
            pos = (pos + 3) & ~3
            streams[name.decode()] = (md_off + s_off, s_size)
        return streams

    def _parse_tables_header(self):
        pos = self.tables_off
        reserved, major, minor, heap_sizes, reserved2 = struct.unpack_from("<IBBBB", self.blob, pos)
        pos += 8
        valid = struct.unpack_from("<Q", self.blob, pos)[0]
        pos += 8
        pos += 8                                     # sorted mask
        counts = {}
        for i in range(64):
            if valid & (1 << i):
                counts[i] = struct.unpack_from("<I", self.blob, pos)[0]
                pos += 4
        return counts, heap_sizes

    def _compute_table_offsets(self):
        offsets = {}
        cur = self.tables_off + 24 + 4 * len(self.counts)
        for t in sorted(self.counts):
            offsets[t] = cur
            size = self.sizes.get(t)
            if size is None:
                raise ValueError(f"неизвестный размер строки таблицы {t:#x}")
            cur += self.counts[t] * size
        return offsets

    # --- публичное ---

    def get_string(self, idx):
        end = self.strings.find(b"\0", idx)
        return self.strings[idx:end].decode("utf-8", "replace")

    def get_blob(self, idx):
        b0 = self.blobs[idx]
        if b0 & 0x80 == 0:
            size, pos = b0, idx + 1
        elif b0 & 0xC0 == 0x80:
            size = ((b0 & 0x3F) << 8) | self.blobs[idx + 1]
            pos = idx + 2
        else:
            size = (((b0 & 0x1F) << 24) | (self.blobs[idx + 1] << 16) |
                    (self.blobs[idx + 2] << 8) | self.blobs[idx + 3])
            pos = idx + 4
        return self.blobs[pos:pos + size]

    def _read_idx(self, off, size):
        if size == 2:
            return struct.unpack_from("<H", self.blob, off)[0]
        return struct.unpack_from("<I", self.blob, off)[0]

    def field_names(self):
        """Список имён полей в порядке таблицы Field."""
        names = []
        if T_FIELD not in self.counts:
            return names
        str_w = bool(self.heap_sizes & 1)
        blob_w = bool(self.heap_sizes & 4)
        row = self.sizes[T_FIELD]
        off = self.table_offsets[T_FIELD]
        for i in range(self.counts[T_FIELD]):
            idx = self._read_idx(off + i * row + 2, 4 if str_w else 2)
            names.append(self.get_string(idx))
        return names

    def param_names(self):
        names = []
        if T_PARAM not in self.counts:
            return names
        str_w = bool(self.heap_sizes & 1)
        row = self.sizes[T_PARAM]
        off = self.table_offsets[T_PARAM]
        for i in range(self.counts[T_PARAM]):
            idx = self._read_idx(off + i * row + 4, 4 if str_w else 2)
            names.append(self.get_string(idx))
        return names

    def const_values(self):
        """Возвращает список (имя_поля, тип, значение) из таблицы Constant."""
        if T_CONSTANT not in self.counts:
            return []
        str_w = bool(self.heap_sizes & 1)
        blob_w = bool(self.heap_sizes & 4)
        coded_size = self.sizes[T_CONSTANT] - 2 - (4 if blob_w else 2)
        row = self.sizes[T_CONSTANT]
        off = self.table_offsets[T_CONSTANT]
        field_names = self.field_names()
        param_names = self.param_names()
        out = []
        for i in range(self.counts[T_CONSTANT]):
            base = off + i * row
            ctype = struct.unpack_from("<H", self.blob, base)[0]
            parent = self._read_idx(base + 2, coded_size)
            val_idx = self._read_idx(base + 2 + coded_size, 4 if blob_w else 2)
            tag = parent & 0x03
            rowno = parent >> 2
            if tag == 0:
                name = field_names[rowno - 1] if 1 <= rowno <= len(field_names) else f"field#{rowno}"
            elif tag == 1:
                name = param_names[rowno - 1] if 1 <= rowno <= len(param_names) else f"param#{rowno}"
            else:
                name = f"property#{rowno}"
            raw = self.get_blob(val_idx)
            out.append((name, ctype, raw))
        return out

    @staticmethod
    def decode_const(ctype, raw):
        """Значение константы по типу из таблицы Constant."""
        kinds = {0x02: "bool", 0x03: "char", 0x04: "i1", 0x05: "u1", 0x06: "i2",
                 0x07: "u2", 0x08: "i4", 0x09: "u4", 0x0A: "i8", 0x0B: "u8",
                 0x0C: "r4", 0x0D: "r8", 0x0E: "string"}
        kind = kinds.get(ctype, f"type{ctype:#x}")
        try:
            if kind == "i4" and len(raw) == 4:
                return struct.unpack_from("<i", raw, 0)[0], kind
            if kind == "u4" and len(raw) == 4:
                return struct.unpack_from("<I", raw, 0)[0], kind
            if kind == "u1" and len(raw) == 1:
                return raw[0], kind
            if kind == "i1" and len(raw) == 1:
                return struct.unpack_from("<b", raw, 0)[0], kind
            if kind == "i2" and len(raw) == 2:
                return struct.unpack_from("<h", raw, 0)[0], kind
            if kind == "u2" and len(raw) == 2:
                return struct.unpack_from("<H", raw, 0)[0], kind
            if kind == "i8" and len(raw) == 8:
                return struct.unpack_from("<q", raw, 0)[0], kind
            if kind == "u8" and len(raw) == 8:
                return struct.unpack_from("<Q", raw, 0)[0], kind
            if kind == "string":
                return raw.decode("utf-16-le", "replace"), kind
        except struct.error:
            pass
        return raw.hex(), kind
