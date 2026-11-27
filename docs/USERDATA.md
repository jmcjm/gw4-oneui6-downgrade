# Userdata: using the whole partition

The factory `userdata.img` is a 2 GiB f2fs on an 8.3 GiB partition (8 942 256 128 bytes on the SM-R870 and the SM-R860). The One UI 6 fstab has no `resize` flag and no `formattable` flag for `/data`, so Android never grows it: about 6.3 GiB of the partition stay unused.

- **Not set up yet:** flash a full-size empty image instead of the factory one (below). This is the easy way.
- **Already set up:** the filesystem can be grown in place without losing data, but only with the procedure in [Growing an existing /data](#growing-an-existing-data). Read [Pitfalls](#pitfalls) first: the obvious ways destroy data.

## New installation

Build an empty f2fs the size of the whole partition, with the same features as the factory image:

```bash
scripts/userdata/make-userdata.sh work/userdata-full.img
```

Flash it in step 6 of [BUILDING.md](BUILDING.md) instead of `work/fw/userdata.img`:

```bash
$F $S work/userdata-full.img userdata
```

The image holds about 23 MiB of data and zeros otherwise, so `flash-chunks.sh` (zstd) sends it quickly. On the first boot vold finds an unencrypted f2fs and encrypts it in place, as it does with the factory image (`encrypt_inplace` in `system/vold/MetadataCrypt.cpp`).

**Status: not tested on a watch.** The image is checked on the host (superblock features identical to the factory image: `encrypt verity extra_attr project_quota quota_ino casefold compression`), and the first-boot path is read from the AOSP 14 source. If the first boot fails, flash the factory `work/fw/userdata.img` and the factory `metadata.img` again.

## Growing an existing /data

Done once on the SM-R870 on 2026-11-27: `/data` went from 2 GiB to 8.3 GiB, root, Magisk modules, apps and their data intact, all APKs in `/data/app` pass a CRC check. The commands below are that run written up; `dmcrypt.py` and `fix-fbe-blocks.py` were re-run on the same inputs and reproduce the image that was written byte for byte. `pull-chunks.sh` and `write-chunks.sh` are generalised from the commands that ran and have not been run in this exact form yet: watch their output.

The idea: the filesystem is grown offline on a Linux PC. Android cannot do it (no `resize` for f2fs in `fs_mgr`), the kernel cannot do it online (f2fs only shrinks online), and in the Wi-Fi recovery `/data` cannot be opened (see [Pitfalls](#pitfalls)). So the metadata encryption key is read from the running kernel, the start of the partition is copied to the PC, decrypted, grown with `resize.f2fs`, encrypted again and written back.

Requirements: root on the watch (Magisk), the Wi-Fi recovery, the kernel build tree the running `boot` was built from (for one module), and on the PC f2fs-tools, `uv` (for the `cryptography` package), `sudo` (loop mount), and about 15 GB of free space. Charge the watch first: the Wi-Fi recovery does not charge on the wireless charger, and the transfers take a while (about 4.7 MB/s, see [Pitfalls](#pitfalls)).

Work in a directory of its own **outside the repository**: every file there holds either the key or decrypted filesystem metadata.

```bash
REPO=$PWD                        # this repository
mkdir -p ~/gw4-userdata && chmod 700 ~/gw4-userdata
cd ~/gw4-userdata || exit
umask 077
```

### 1. Read the metadata encryption key

`/data` sits on a `dm-default-key` device (`userdata`). Its table (from Android, as root):

```
dmctl table userdata
0-17465344: default-key, aes-xts-plain64 - 0 259:28 0 3 allow_discards sector_size:4096 iv_large_sectors
```

The kernel does not show the key (`/* Omit the key for now. */` in `dm-default-key.c`), so a one-shot module reads it. Build `scripts/userdata/gw4dmkey.c` against the kernel tree of the running kernel, with the toolchain from `work/toolchains`. Its `vermagic` must equal `uname -r` on the watch, and with `CONFIG_MODVERSIONS` the symbol CRCs must match too, otherwise `insmod` refuses the module.

```bash
podman run --rm -v "$KSRC:/work/kernel:ro,z" -v "$KOUT:/work/out:ro,z" \
  -v "$REPO/work/toolchains:/tc:ro,z" -v "$REPO/scripts/userdata:/mod:Z" -w /mod \
  localhost/gw4-kbuild-bookworm:amd64 make -C /work/kernel O=/work/out M=/mod ARCH=arm64 \
  CROSS_COMPILE=/tc/aarch64-linux-android-4.9/bin/aarch64-linux-android- \
  CC=/tc/clang-r383902/bin/clang CLANG_TRIPLE=aarch64-linux-gnu- modules
```

The dm table functions it needs are not exported, and neither is `kallsyms_lookup_name`, so their addresses are passed as parameters. The module checks the key size, sector size, target type, cipher and underlying device before it reads the key, and exposes it only in `/proc/gw4_dmkey` (mode 0400), not in the kernel log. Set `dm_minor`, `disk_major` and `disk_minor` if the table differs from the defaults (`253:35` over `259:28`; the minors are in `dmctl list devices` and `ls -l /dev/block/mmcblk0p*`). The kernel command line has `oops=panic`, so a wrong module means a reboot, not an oops.

```bash
adb push "$REPO/scripts/userdata/gw4dmkey.ko" /data/local/tmp/
adb shell su -c '
  echo 0 > /proc/sys/kernel/kptr_restrict
  a() { grep " T $1\$" /proc/kallsyms | cut -d" " -f1; }
  P="get_live_table=0x$(a dm_get_live_table) put_live_table=0x$(a dm_put_live_table) table_get_target=0x$(a dm_table_get_target) table_num_targets=0x$(a dm_table_get_num_targets)"
  echo 2 > /proc/sys/kernel/kptr_restrict
  insmod /data/local/tmp/gw4dmkey.ko $P'
adb exec-out su -c 'cat /proc/gw4_dmkey' > dmkey.txt
adb shell su -c 'rmmod gw4dmkey; rm /data/local/tmp/gw4dmkey.ko'
```

`dmkey.txt` lists the key and the table parameters; compare them with the `dmctl` line. Check the key on the first block of the partition, and read the size of the filesystem from its superblock. The decrypted block must hold the f2fs magic at offset 1024:

```bash
KEY=$(awk '$1=="key"{print $2}' dmkey.txt)
adb exec-out su -c 'dd if=/dev/block/by-name/userdata bs=4096 count=1' > blk0.enc
KEY=$KEY uv run --no-project --with cryptography python -I "$REPO/scripts/userdata/dmcrypt.py" decrypt < blk0.enc > blk0.dec
python3 -c 'import struct,sys; b=open("blk0.dec","rb").read()[1024:]; m,=struct.unpack_from("<I",b,0); n,=struct.unpack_from("<Q",b,0x24); print(hex(m), n, "blocks ->", -(-n*4096//(128<<20))*128, "MiB to pull")'
# 0xf2f52010 524288 blocks -> 2048 MiB to pull
MIB=2048                         # the value printed above
```

### 2. Back up (Wi-Fi recovery)

Reboot into the Wi-Fi recovery (`adb reboot recovery`). Keep a copy of the vold keys on `/metadata`, then copy the start of `userdata` (the size from step 1), each 128 MiB chunk checked against a hash computed on the watch:

```bash
S=gw4-recovery.lan:5555
mkdir -m 700 backup
adb -s $S shell 'mkdir -p /tmp/md && mount -t ext4 -o ro /dev/block/by-name/metadata /tmp/md && tar -C /tmp/md -cf /tmp/metadata.tar .; umount /tmp/md'
adb -s $S pull /tmp/metadata.tar backup/ && adb -s $S shell rm /tmp/metadata.tar
tar -tf backup/metadata.tar | grep metadata_encryption     # the vold key directory must be there
"$REPO/scripts/userdata/pull-chunks.sh" $S backup $MIB
```

`backup/` is the way back: `"$REPO/scripts/userdata/write-chunks.sh" $S backup` restores the partition exactly as it was. Only the backed-up range matters, because the old superblock describes a filesystem of that size.

### 3. Grow the filesystem on the PC

```bash
cat backup/userdata-enc.?? > orig-enc.img
KEY=$KEY uv run --no-project --with cryptography python -I "$REPO/scripts/userdata/dmcrypt.py" decrypt < orig-enc.img > replayed.img
fsck.f2fs --dry-run replayed.img        # must pass; note the checkpoint state
```

The checkpoint is usually `sudden-power-off` (the reboot into the recovery does not unmount `/data` cleanly), and `resize.f2fs` refuses such an image ("Mount unclean image to replay log first"). Let the PC kernel replay the log once, without background GC or discard:

```bash
sudo mount -t f2fs -o loop,background_gc=off,nodiscard replayed.img /mnt && sudo umount /mnt
fsck.f2fs --dry-run replayed.img        # checkpoint state now "unmount"
```

Grow a copy to the size of the partition and check it:

```bash
cp --sparse=always replayed.img resized.img
truncate -s 8942256128 resized.img
resize.f2fs resized.img
fsck.f2fs -f --dry-run resized.img      # total FS sectors = 17465344 (8528 MB), no errors
```

Encrypt the backed-up range again and repair the relocated file blocks (the step that matters, see [Pitfalls](#pitfalls)):

```bash
head -c $(stat -c %s orig-enc.img) resized.img \
  | KEY=$KEY uv run --no-project --with cryptography python -I "$REPO/scripts/userdata/dmcrypt.py" encrypt > resized-enc.img
uv run --no-project python -I "$REPO/scripts/userdata/fix-fbe-blocks.py" replayed.img resized.img orig-enc.img resized-enc.img
mkdir -m 700 chunks && split -b 134217728 -d -a 2 resized-enc.img chunks/userdata-enc.
(cd chunks && sha256sum userdata-enc.* > SHA256SUMS)
```

`fix-fbe-blocks.py` stops without writing anything when it is unsure: when `resize.f2fs` wrote anything beyond the backed-up range, when a block of an encrypted file has a duplicate, or when a block changes owner. On the R870 it reported: main area 6656 → 17408, 6064 relocated blocks of FBE file data from 235 inodes. The free space beyond the backed-up range needs nothing: f2fs never reads a free block before writing it.

### 4. Write and check

Still in the Wi-Fi recovery:

```bash
"$REPO/scripts/userdata/write-chunks.sh" $S chunks     # must end with WRITE_DONE (16 chunks)
adb -s $S reboot
```

In Android: `df -h /data` shows about 8.3 GiB, `su -c id` works, and the APKs in `/data/app` pass a CRC check (pull them and test with Python `zipfile.ZipFile(f).testzip()`; `unzip -t` also complains about the page-alignment extra field in some Samsung APKs, which is harmless). Then delete `dmkey.txt`, `blk0.*`, `replayed.img`, `resized*.img`, `orig-enc.img` and `chunks/`; keep `backup/` until the watch has been in use for a while.

## Pitfalls

**FBE file contents bypass dm-default-key.** With `fileencryption=...` and the `inlinecrypt` mount option, file contents are encrypted by blk-crypto with the file key, and dm-default-key passes such bios through untouched. On disk, file data blocks carry only FBE; node blocks, directories and unencrypted files carry the metadata layer. When `resize.f2fs` grows NAT and SSA, the main area start moves (R870: from block 6656 to 17408) and blocks are copied elsewhere. Copied through the metadata layer (decrypt with the old block number, encrypt with the new one) the file data blocks turn into garbage. The first attempt on the R870 did exactly that: 6064 blocks in 235 files, including the Magisk app and `/data/adb`; Magisk then showed "not installed" and refused `su` to everyone. `fix-fbe-blocks.py` writes those blocks raw from the backup. For the same reason **never run `resize.f2fs` on the watch through a dm-default-key device**: it reads and writes through the metadata layer and destroys the same blocks.

**No dm-default-key in the Wi-Fi recovery.** Creating the same `default-key` mapping in the recovery (kernel 5.15.180 of `R870XXS2JZG3`) and reading from it panicked the kernel (`reset_reason=4`); the partition stayed intact. On Android (4.19) the same read-only mapping works. That is why the resize runs on the PC and the recovery only copies raw chunks.

**The checkpoint after `adb reboot recovery` is unclean.** Replay it with a mount before `resize.f2fs`, as above. A replay by the PC kernel is fine: it does not touch the contents of encrypted files.

**Do not trust a "matches the device" check alone.** Encrypting the unmodified decrypted image gives back the device contents byte for byte even though the FBE blocks are garbage in the decrypted image: XTS decrypt and encrypt with the same block number cancel out. Only moved blocks show the problem.

**`adb` inside a `while read` loop eats the loop's input.** `adb shell` forwards its stdin to the watch; a write loop fed from a file stops after the first iteration and still reports success. The scripts run every `adb` with `</dev/null` and count the chunks they handled.

**Wi-Fi speed.** The Wi-Fi chip runs 20 MHz channels only (the 40 MHz power tables in its nvram are commented out), so a 1×1 802.11n link tops out at 65–72 Mbit/s on both bands: about 4.7 MB/s through adb, 2 GiB in about 8 minutes. 5 GHz does not help.
