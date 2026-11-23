#!/usr/bin/env python3
"""Removes the Samsung signature footer from a vbmeta or dtbo image.

Samsung appends a footer ("SignerVer03", the firmware version, the key
name) after the image data. The bootloader reads the binary revision from
that footer: on bootloader rev2, images signed for rev1 fail with
"CHECK FAIL ... DEVICE: 2, BINARY: 1". Without the footer the image is a
custom binary, which an unlocked bootloader accepts.

The image is cut to the length its own header declares and padded with
zeros to the partition size.

Usage:
  strip-signature.py vbmeta <in> <out> <partition size> [--disable-verification]
  strip-signature.py dtbo   <in> <out> <partition size>

--disable-verification sets the vbmeta flags to 3 (hashtree and
verification disabled).
"""
import struct
import sys

AVB_MAGIC = b"AVB0"
DT_TABLE_MAGIC = 0xD7B7AB1E


def vbmeta_length(data):
    if data[:4] != AVB_MAGIC:
        sys.exit("not a vbmeta image")
    auth, aux = struct.unpack(">QQ", data[12:28])
    return 256 + auth + aux


def dtbo_length(data):
    magic, total = struct.unpack(">II", data[:8])
    if magic != DT_TABLE_MAGIC:
        sys.exit("not a dtbo image")
    return total


def main():
    args = sys.argv[1:]
    disable = "--disable-verification" in args
    args = [a for a in args if a != "--disable-verification"]
    if len(args) != 4:
        sys.exit(__doc__)
    kind, src, dst, size = args[0], args[1], args[2], int(args[3])

    data = open(src, "rb").read()
    if kind == "vbmeta":
        length = vbmeta_length(data)
    elif kind == "dtbo":
        if disable:
            sys.exit("--disable-verification applies to vbmeta only")
        length = dtbo_length(data)
    else:
        sys.exit("kind must be vbmeta or dtbo")

    if length > size:
        sys.exit("image data (%d B) larger than the partition (%d B)" % (length, size))
    out = bytearray(data[:length])
    if disable:
        out[120:124] = struct.pack(">I", 3)
    out += b"\0" * (size - length)
    open(dst, "wb").write(out)


if __name__ == "__main__":
    main()
