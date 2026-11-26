#!/usr/bin/env python3
"""Generate a tiny COFF import library for legacy UCRT symbol names.

LDC's MSVC-target import libraries cover the normal UCRT exports, but the
Phobos modules pulled in by a hot-loaded script also reference a handful of
POSIX-ish names (`execv`, `fileno`, `open`, ...). On a development machine
Visual Studio's `oldnames.lib` resolves those against the CRT; a released user
has no Visual Studio. LDC ships an `oldnames.lib` that maps them to a MinGW
shim DLL, which does not exist on Windows.

This module writes a small import library instead, pointing those names at
`ucrtbase.dll`, which is part of Windows. The import descriptors are a fixed
COFF template (they depend only on the DLL name); the per-symbol short import
objects are generated here. No external tool is needed on the build machine.
"""

import base64
import struct

DLL = b"ucrtbase.dll"

# Symbols from the LDC import libraries that are not covered by the normal
# UCRT import library. Sourced from the intersection of Phobos/druntime's
# undefined symbols and the legacy alias list in LDC's oldnames library.
SYMBOLS = [
    "close",
    "execv",
    "execve",
    "execvp",
    "execvpe",
    "fdopen",
    "fileno",
    "getpid",
    "open",
    "putenv",
    "read",
    "strdup",
    "tzset",
    "write",
]

# Fixed COFF objects for the import descriptor, its terminator and the null
# thunk. Generated once from the import-library layout; symbol objects are
# appended by this script. They only encode the DLL name, never symbol names.
_DESCRIPTOR = base64.b64decode(
    "ZIYCAAAAAACjAAAABwAAAAAAAAAuaWRhdGEkMgAAAAAAAAAAFAAAAGQAAAB4AAAAAAAAAAMAAABAADDALmlkYXRhJDYAAAAAAAAAAA0AAACWAAAAAAAAAAAAAAAAAAAAQAAgwAAAAAAAAAAAAAAAAAAAAAAAAAAADAAAAAIAAAADAAAAAAADAAAAAwAQAAAABAAAAAMAdWNydGJhc2UuZGxsAAAAAAAEAAAAAAAAAAEAAAACAC5pZGF0YSQyAAAAAAEAAABoAC5pZGF0YSQ2AAAAAAIAAAADAC5pZGF0YSQ0AAAAAAAAAABoAC5pZGF0YSQ1AAAAAAAAAABoAAAAAAAhAAAAAAAAAAAAAAACAAAAAAA6AAAAAAAAAAAAAAACAFQAAABfX0lNUE9SVF9ERVNDUklQVE9SX3VjcnRiYXNlAF9fTlVMTF9JTVBPUlRfREVTQ1JJUFRPUgB/dWNydGJhc2VfTlVMTF9USFVOS19EQVRBAA=="
)
_NULL_DESCRIPTOR = base64.b64decode(
    "ZIYBAAAAAABQAAAAAQAAAAAAAAAuaWRhdGEkMwAAAAAAAAAAFAAAADwAAAAAAAAAAAAAAAAAAABAADDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAABAAAAAgAdAAAAX19OVUxMX0lNUE9SVF9ERVNDUklQVE9SAA=="
)
_NULL_THUNK = base64.b64decode(
    "ZIYCAAAAAAB0AAAAAQAAAAAAAAAuaWRhdGEkNQAAAAAAAAAACAAAAGQAAAAAAAAAAAAAAAAAAABAAEDALmlkYXRhJDQAAAAAAAAAAAgAAABsAAAAAAAAAAAAAAAAAAAAQABAwAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAABAAAAAgAeAAAAf3VjcnRiYXNlX05VTExfVEhVTktfREFUQQA="
)


def _short_import(name):
    """Short COFF import object defining both `__imp_name` and `name`."""
    symbol = name.encode("ascii")
    data = symbol + b"\0" + DLL + b"\0"
    header = struct.pack(
        "<HHHHIIHH",
        0,             # Sig1
        0xFFFF,        # Sig2
        0,             # Version
        0x8664,        # Machine: AMD64
        0,             # TimeDateStamp
        len(data),     # SizeOfData
        0,             # Ordinal/Hint
        0x0004,        # Import by name, CODE type
    )
    return header + data


def _member_header(name, size, mode="644"):
    return (
        f"{name:<16}{'0':<12}{'0':<6}{'0':<6}{mode:<8}{size:<10}`\n"
    ).encode("ascii")


def build(symbols=SYMBOLS):
    """Return the bytes of a `dcad-crt-legacy.lib` COFF import library."""
    objects = [_DESCRIPTOR, _NULL_DESCRIPTOR, _NULL_THUNK]
    # The first linker member lists symbols in object-emission order.
    listed = [
        (b"__IMPORT_DESCRIPTOR_ucrtbase", 0),
        (b"__NULL_IMPORT_DESCRIPTOR", 1),
        (b"\x7fucrtbase_NULL_THUNK_DATA", 2),
    ]
    for index, symbol in enumerate(symbols):
        objects.append(_short_import(symbol))
        member = 3 + index
        listed.append((b"__imp_" + symbol.encode("ascii"), member))
        listed.append((symbol.encode("ascii"), member))

    first_size = 4 + 4 * len(listed) + sum(len(name) + 1 for name, _ in listed)
    first_size += first_size & 1
    second_size = 4 + 4 * len(objects) + 4 + 2 * len(listed)
    second_size += sum(len(name) + 1 for name, _ in listed)
    second_size += second_size & 1

    offset = 8 + 60 + first_size + 60 + second_size
    offsets = []
    for obj in objects:
        offsets.append(offset)
        offset += 60 + len(obj) + (len(obj) & 1)

    first = struct.pack(">I", len(listed))
    first += b"".join(struct.pack(">I", offsets[member]) for _, member in listed)
    first += b"".join(name + b"\0" for name, _ in listed)
    first += b"\0" * (len(first) & 1)

    # The second linker member stores symbols sorted by name.
    sorted_listed = sorted(listed, key=lambda item: item[0])
    second = struct.pack("<I", len(objects))
    second += b"".join(struct.pack("<I", value) for value in offsets)
    second += struct.pack("<I", len(sorted_listed))
    second += b"".join(struct.pack("<H", member + 1) for _, member in sorted_listed)
    second += b"".join(name + b"\0" for name, _ in sorted_listed)
    second += b"\0" * (len(second) & 1)

    out = bytearray(b"!<arch>\n")
    out += _member_header("/", len(first), "0") + first
    out += _member_header("/", len(second), "0") + second
    for obj in objects:
        out += _member_header("ucrtbase.dll/", len(obj))
        out += obj
        if len(obj) & 1:
            out += b"\n"
    return bytes(out)


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 2:
        raise SystemExit("usage: make_crt_lib.py <output.lib>")
    with open(sys.argv[1], "wb") as stream:
        stream.write(build())
