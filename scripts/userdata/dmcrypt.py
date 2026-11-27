#!/usr/bin/env python3
"""Encrypts or decrypts a userdata image the way dm-default-key does on the
watch: aes-xts-plain64, 4096-byte sectors, iv_large_sectors, iv_offset 0, so
the IV of every 4 KiB block is its block number.

    KEY=<hex> dmcrypt.py decrypt < encrypted.img > plain.img
    KEY=<hex> dmcrypt.py encrypt < plain.img > encrypted.img

The key comes from the KEY environment variable (128 hex digits), never from
the command line. Needs the 'cryptography' package
(uv run --with cryptography python -I dmcrypt.py ...).

The "plain" image is plain only at the metadata layer: with inlinecrypt the
contents of FBE-encrypted files bypass dm-default-key, so those blocks are
garbage in the plain image (see docs/USERDATA.md).
"""
import os
import struct
import sys

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

BLOCK = 4096


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in ("encrypt", "decrypt"):
        print(__doc__, file=sys.stderr)
        return 2
    key = bytes.fromhex(os.environ["KEY"])
    if len(key) != 64:
        print("KEY must be 64 bytes (AES-256-XTS)", file=sys.stderr)
        return 2
    encrypt = sys.argv[1] == "encrypt"
    inp, out = sys.stdin.buffer, sys.stdout.buffer
    block = 0
    while True:
        buf = inp.read(BLOCK * 256)
        if not buf:
            break
        if len(buf) % BLOCK:
            print("input is not a multiple of 4096 bytes", file=sys.stderr)
            return 1
        res = bytearray()
        for off in range(0, len(buf), BLOCK):
            c = Cipher(algorithms.AES(key), modes.XTS(struct.pack("<QQ", block, 0)))
            op = c.encryptor() if encrypt else c.decryptor()
            res += op.update(buf[off:off + BLOCK])
            block += 1
        out.write(res)
    return 0


if __name__ == "__main__":
    sys.exit(main())
