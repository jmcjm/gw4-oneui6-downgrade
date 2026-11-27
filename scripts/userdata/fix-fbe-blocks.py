#!/usr/bin/env python3
"""Repairs the FBE file blocks that resize.f2fs relocated.

    fix-fbe-blocks.py <replayed.img> <resized.img> <orig-enc.img> <resized-enc.img>

replayed.img    metadata-decrypted image after the log replay, before resize
resized.img     the same image after resize.f2fs (full partition size)
orig-enc.img    the encrypted image as read from the watch (the backup)
resized-enc.img the start of resized.img encrypted again with dmcrypt.py, as
                long as orig-enc.img; patched in place

When resize.f2fs grows NAT and SSA, the main area start moves and blocks are
copied elsewhere: either only those in the old [main, new main) range
(defragmentation, the case seen on the SM-R870) or the whole main area
(migration, which leaves the old copies in place; handled the same way, but
not seen on a watch yet). Node and directory
blocks go through dm-default-key, so decrypting, moving and encrypting them
again is correct. The contents of FBE-encrypted regular files do not: with
inlinecrypt they are stored encrypted with the file key only, and encrypting
them under a new block number destroys them. For each such block this script
writes the raw bytes from its old address in the backup to its new address.

Relocated data blocks are found by content in the whole old main area
(resize.f2fs copies data blocks unchanged). A block counts only if its
content occurs exactly once before and at exactly one new address after
the resize, and its old
and new address belong to the same inode (dump.f2fs -b). An inode is an
encrypted file when it is a regular file with FADVISE_ENCRYPT_BIT (0x04) in
i_advise. Any doubt stops the script before anything is written.
"""
import collections
import hashlib
import os
import re
import struct
import subprocess
import sys

BLOCK = 4096


class Stop(Exception):
    pass


def superblock(path: str):
    with open(path, "rb") as f:
        sb = f.read(BLOCK)[1024:]
    if struct.unpack_from("<I", sb, 0)[0] != 0xF2F52010:
        raise Stop(f"{path}: no f2fs superblock")
    block_count = struct.unpack_from("<Q", sb, 0x24)[0]
    main = struct.unpack_from("<6I", sb, 0x48)[5]
    return main, block_count


def dump(args, marker):
    # The exit code is not reliable (dump.f2fs -i returns 255 for some valid
    # inodes after printing them), so the output must contain the marker.
    r = subprocess.run(["dump.f2fs", *args], capture_output=True, text=True)
    if marker not in r.stdout:
        raise Stop(f"dump.f2fs {' '.join(args)}: unexpected output (rc {r.returncode}): "
                   f"{(r.stdout + r.stderr).strip()[-200:]}")
    return r.stdout


def owner(img: str, addr: int):
    """(is a data block, owning inode) of a main area block."""
    out = dump(["-b", str(addr), img], "Dump data from block address")
    is_data = "Data block" in out
    m = re.search(r"Inode block\s*: id = 0x([0-9a-f]+)", out)
    if is_data and not m:
        raise Stop(f"block {addr} of {img}: data block without an owning inode in dump.f2fs output")
    return is_data, (int(m.group(1), 16) if m else None)


def inode_mode_advise(img: str, ino: int):
    out = dump(["-i", str(ino), img], "is inode")
    mode = re.search(r"i_mode\s+\[0x\s*([0-9a-f]+)", out)
    adv = re.search(r"i_advise\s+\[0x\s*([0-9a-f]+)", out)
    if not mode or not adv:
        raise Stop(f"inode {ino}: no i_mode/i_advise in dump.f2fs output")
    return int(mode.group(1), 16), int(adv.group(1), 16)


def hashes(path: str, start: int, end: int):
    """sha256 -> list of block addresses, for non-zero blocks in [start, end)."""
    res = collections.defaultdict(list)
    with open(path, "rb") as f:
        f.seek(start * BLOCK)
        a = start
        while a < end:
            buf = f.read(BLOCK * min(256, end - a))
            if not buf:
                break
            for i in range(0, len(buf), BLOCK):
                blk = buf[i:i + BLOCK]
                if blk.count(0) != BLOCK:
                    res[hashlib.sha256(blk).digest()].append(a + i // BLOCK)
            a += len(buf) // BLOCK
    return res


def data_extents(path: str):
    fd = os.open(path, os.O_RDONLY)
    try:
        size, off = os.fstat(fd).st_size, 0
        while off < size:
            try:
                d = os.lseek(fd, off, os.SEEK_DATA)
            except OSError:
                return
            h = os.lseek(fd, d, os.SEEK_HOLE)
            yield d, h
            off = h
    finally:
        os.close(fd)


def run(replayed, resized, orig_enc, resized_enc):
    old_main, old_count = superblock(replayed)
    new_main, _ = superblock(resized)
    prefix = os.path.getsize(resized_enc) // BLOCK
    if os.path.getsize(orig_enc) // BLOCK != prefix:
        raise Stop("orig-enc.img and resized-enc.img differ in size")
    if old_count > prefix:
        raise Stop(f"the old filesystem ({old_count} blocks) is larger than the backup ({prefix} blocks)")
    print(f"main area {old_main} -> {new_main}, old filesystem {old_count} blocks, backup {prefix} blocks")
    if new_main == old_main:
        print("main area did not move: nothing was relocated")
        return

    # Everything resize.f2fs wrote must lie in the part that gets written back.
    with open(resized, "rb") as f:
        for d, h in data_extents(resized):
            start = max(d, prefix * BLOCK)
            if h <= start:
                continue
            f.seek(start)
            while f.tell() < h:
                chunk = f.read(min(1 << 20, h - f.tell()))
                if chunk.count(0) != len(chunk):
                    raise Stop(f"resized.img has data near byte {f.tell()}, beyond the backup; "
                               "pull a larger backup")

    before = hashes(replayed, old_main, old_count)
    after = hashes(resized, new_main, prefix)
    moved = []
    for h, olds in before.items():
        news = [n for n in after.get(h, []) if n not in olds]
        if not news:
            continue
        if len(olds) != 1 or len(news) != 1:
            # Identical contents: harmless unless it is data of an encrypted file.
            for o in olds:
                is_data, ino = owner(replayed, o)
                if is_data:
                    mode, adv = inode_mode_advise(replayed, ino)
                    if (mode & 0xF000) == 0x8000 and adv & 0x04:
                        raise Stop(f"block {o} of encrypted inode {ino} has duplicate contents; "
                                   "its new address is ambiguous")
            continue
        moved.append((olds[0], news[0]))
    print(f"relocated blocks found by content: {len(moved)}")

    info, fbe, kinds = {}, [], collections.Counter()
    for o, n in moved:
        is_data, ino = owner(replayed, o)
        if not is_data:
            kinds["node"] += 1
            continue
        n_data, n_ino = owner(resized, n)
        if not n_data or n_ino != ino:
            raise Stop(f"block {o} -> {n}: inode {ino} before, {n_ino} after the resize")
        if ino not in info:
            info[ino] = inode_mode_advise(replayed, ino)
        mode, adv = info[ino]
        enc_reg = (mode & 0xF000) == 0x8000 and adv & 0x04
        kinds["fbe file data" if enc_reg else "other data"] += 1
        if enc_reg:
            if n >= prefix:
                raise Stop(f"block {o} moved to {n}, beyond the backup")
            fbe.append((o, n))
    print(dict(kinds), f"from {len(info)} inodes")

    with open(orig_enc, "rb") as src, open(resized_enc, "r+b") as dst:
        for o, n in fbe:
            src.seek(o * BLOCK)
            dst.seek(n * BLOCK)
            dst.write(src.read(BLOCK))
        dst.flush()
        os.fsync(dst.fileno())
    with open(os.path.join(os.path.dirname(os.path.abspath(resized_enc)), "fbe-moved.txt"), "w") as f:
        f.writelines(f"{o} {n}\n" for o, n in fbe)
    print(f"patched {len(fbe)} FBE file blocks with their original raw bytes")


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        run(*sys.argv[1:])
    except Stop as e:
        print(f"STOP: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
