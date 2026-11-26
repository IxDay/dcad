#!/usr/bin/env python3
"""Guard the launcher ZIP layout used by the self-extracting binary."""

import sys
import zipfile


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: check_payload.py <payload.bin>")
    payload = sys.argv[1]
    with zipfile.ZipFile(payload) as zf:
        names = zf.namelist()
        manifest = zf.read("embedded.manifest").decode("utf-8")
        if "dcad=1\n" not in manifest:
            raise SystemExit("launcher payload is missing the embedded GUI")
        nested = [name for name in names if name.startswith("lib/lib/")]
        if nested:
            raise SystemExit(
                "launcher payload has doubly nested libraries, e.g. " + nested[0]
            )
        if "libs=1\n" in manifest:
            libs = [name for name in names if name.startswith("lib/")]
            if not libs:
                raise SystemExit("manifest reports embedded libs but none are stored")
    print("PASS: launcher payload layout")


if __name__ == "__main__":
    main()
