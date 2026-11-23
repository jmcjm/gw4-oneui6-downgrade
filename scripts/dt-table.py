#!/usr/bin/env python3
"""Replaces the device tree in the dtb section of a Samsung boot image.

The dtb section of the R870XXU1IYI1 boot image is a dt_table (the same
format as dtbo) with one entry. The header and the entry are kept; only
the total size and the entry size change.

Usage:
  dt-table.py extract <section> <out.dtb>
  dt-table.py replace <section> <new.dtb> <out section>
"""
import struct
import sys

MAGIC = 0xD7B7AB1E
HEADER = 32
ENTRY = 32


def parse(section):
    magic, total, hdr, entry_size, count, entries = struct.unpack(">IIIIII", section[:24])
    if magic != MAGIC:
        sys.exit("not a dt_table")
    if hdr != HEADER or entry_size != ENTRY or count != 1 or entries != HEADER:
        sys.exit("expected a dt_table with exactly one entry")
    dt_size, dt_offset = struct.unpack(">II", section[HEADER:HEADER + 8])
    if dt_offset != HEADER + ENTRY or dt_offset + dt_size != total:
        sys.exit("unexpected dt_table layout")
    return dt_size, dt_offset


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    section = open(sys.argv[2], "rb").read()
    dt_size, dt_offset = parse(section)

    if cmd == "extract" and len(sys.argv) == 4:
        open(sys.argv[3], "wb").write(section[dt_offset:dt_offset + dt_size])
    elif cmd == "replace" and len(sys.argv) == 5:
        dtb = open(sys.argv[3], "rb").read()
        head = bytearray(section[:dt_offset])
        struct.pack_into(">I", head, 4, dt_offset + len(dtb))
        struct.pack_into(">I", head, HEADER, len(dtb))
        open(sys.argv[4], "wb").write(bytes(head) + dtb)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
