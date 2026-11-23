# Building and flashing

## Before you start

- **Bootloader unlocked**, watch on One UI 8 Watch `R870XXS2JZG3` with Magisk.
- **[gw4-wifi-recovery](https://github.com/jmcjm/gw4-wifi-recovery) installed** on the recovery partition. All flashing below happens from it, and it is the way back when One UI 6 does not boot. It has its own kernel and device tree, so it keeps working whatever is in `boot`.
- **A backup of the One UI 8 partitions** (step 1). Going back means writing them again.
- **Charged battery.** `super` is 5 GiB and goes over 2.4 GHz Wi-Fi at about 5.5 MB/s.

Host tools: `podman`, `curl`, `unzip`, `tar`, `git`, `lz4`, `simg2img`, `lpunpack`, `debugfs` (e2fsprogs), `python3`, `adb`. On Fedora: `android-tools e2fsprogs lz4 podman`.

## 1. Back up One UI 8

From the Wi-Fi recovery (`adb connect gw4-recovery.lan:5555`):

```bash
S=gw4-recovery.lan:5555
mkdir -p backup-JZG3 && cd backup-JZG3
for p in boot dtbo vbmeta vbmeta_system recovery metadata efs sec_efs cpefs keydata keyrefuge param up_param misc; do
    adb -s $S pull /dev/block/by-name/$p $p.img
done
adb -s $S pull /dev/block/by-name/super super.img   # 5 GiB
sha256sum *.img > SHA256SUMS
adb -s $S shell 'cd /dev/block/by-name && sha256sum boot dtbo vbmeta vbmeta_system super'
```

Compare the hashes from the watch with `SHA256SUMS` before going on. Pulling `super` from recovery instead of from Android also avoids overheating the watch.

## 2. Inputs

| Input | Where from |
|---|---|
| Magisk APK (31.1 used here) | [Magisk releases](https://github.com/topjohnwu/Magisk/releases) |
| One UI 6 firmware `R870XXU1IYI1` | any Samsung firmware mirror; the `AP_R870XXU1IYI1_..._meta_WATCH_OS14.tar.md5` from it |
| One UI 8 vendor or super image `R870XXS2JZG3` | the `super.img` from step 1, or the `super.img.lz4` of the `R870XXS2JZG3` AP |
| IYI1 `boot.img` patched with Magisk | step 4 |

## 3. Kernel

```bash
./build.sh tools Magisk-v31.1.apk   # x86_64 magiskboot -> tools/
./build.sh toolchain                # AOSP clang-r383902 and binutils 2.27, ~400 MB
./build.sh source                   # Samsung source (~215 MB) + kernel/patches
./build.sh kernel                   # in a Debian bookworm container
```

`source` downloads the three packages listed in `kernel/sources.txt` from opensource.samsung.com and checks their SHA-256. It unpacks them in order (base `R860XXU1IXK1`, then the SM-R870 device tree and `exynos5515-freshbl_defconfig`, then the `R870XXU1IYI1` kernel update) and applies the patches.

`kernel` builds `exynos5515-freshbl_defconfig` with the options in `kernel/nouh.config` disabled. The host programs of the 4.19 tree do not build with current OpenSSL and without libyaml, hence the container. The banner values (`KBUILD_BUILD_*` in `build.sh`) are those of the tested build, so the result is byte for byte the tested kernel; its hash is in `STATUS.md`.

## 4. Firmware, trustlets, Magisk boot image

```bash
./build.sh firmware AP_R870XXU1IYI1_..._meta_WATCH_OS14.tar.md5   # -> work/fw/
./build.sh trustlets backup-JZG3/super.img                       # -> work/trustlets/
```

`trustlets` takes the `vendor` partition out of the super image (or a vendor image directly), copies `/tee` and checks the files against `overlay/trustlets-R870XXS2JZG3.sha256`.

Patch `work/fw/boot.img` with Magisk: copy it to the watch while it still runs One UI 8 with Magisk, open the Magisk app, **Install → Select and Patch a File**, and copy the `magisk_patched-*.img` back. With Magisk 31.1 the result was `6918cec4…` (`STATUS.md`).

## 5. Images

```bash
./build.sh images magisk_patched-31100.img   # -> work/images/
```

| Output | Built from |
|---|---|
| `boot.img` | the Magisk-patched IYI1 image with the 4.19 kernel from step 3 (Magisk's DEFEX hexpatch, gzip), the IYI1 device tree adapted by `scripts/patch-dts.py` (the two nodes for the bootloader overlay, the second core's MPIDR and `cpu-map`, the rev2 `exynos-cpupm` node), and in the ramdisk the overlay with the JZG3 trustlets and the rebuilt kernel modules |
| `dtbo.img`, `vbmeta_system.img` | stock IYI1 without the Samsung signature footer |
| `vbmeta.img` | stock IYI1 without the footer, flags `3` |

The One UI 6 `super`, `metadata` and `userdata` are used as they are, from `work/fw/`.

## 6. Flash

With the watch in the Wi-Fi recovery:

```bash
S=gw4-recovery.lan:5555
F=scripts/flash-chunks.sh
$F $S work/images/boot.img boot
$F $S work/images/dtbo.img dtbo
$F $S work/images/vbmeta.img vbmeta
$F $S work/images/vbmeta_system.img vbmeta_system
$F $S work/fw/metadata.img metadata
$F $S work/fw/userdata.img userdata
$F $S work/fw/super.img super
adb -s $S shell reboot
```

`flash-chunks.sh` sends 128 MiB chunks with `adb push -z zstd`, writes each with `dd` at its offset, reads it back and finally compares the hash of the whole written range with the image. Do not use `adb exec-in` for this: in this recovery it truncates long streams.

`userdata` is the factory image: a 2 GiB f2fs on a larger partition, the same as Odin writes. The One UI 6 fstab has no `resize`, so `/data` stays 2 GiB.

The first boot takes long (metadata encryption setup, ART). The boot animation appears after about 45 s.

After the first boot, install the Magisk app (`adb install Magisk-v31.1.apk` over wireless debugging), let it finish its setup and reboot; if `su` is still missing, clear the app's data. For ADB on a fixed port after every boot, install the `adb-wifi-keep` module (README). **Never use Install → Direct Install** (or any other way of patching `boot` from the app): Magisk restores the stock ramdisk from its backup before patching, which drops the TEE and module overlay, and the next boot stays on a black screen.

If a boot fails, force a reboot into recovery (hold both keys, then choose recovery from the bootloader menu) and read the log of the failed boot:

```bash
adb -s gw4-recovery.lan:5555 shell cat /proc/last_kmsg > last_kmsg.txt
```

It holds the bootloader log and the kernel log of the previous boot; a forced reset keeps it.

## Back to One UI 8

From the Wi-Fi recovery, with the backup from step 1:

```bash
S=gw4-recovery.lan:5555
F=scripts/flash-chunks.sh
for p in boot dtbo vbmeta vbmeta_system; do $F $S backup-JZG3/$p.img $p; done
$F $S backup-JZG3/super.img super
```

Then write empty `metadata` and `userdata`: the factory `metadata.img` and `userdata.img` of the `R870XXS2JZG3` AP (unpacked the same way as in step 4, `lz4 -d` and `simg2img`). The backed-up `metadata` holds the encryption keys of user data that no longer exists, and the One UI 6 data cannot be used by One UI 8. Reboot; set the watch up again.

If even the recovery does not start, Wireless Download still accepts the stock signed `boot`, `dtbo`, `vbmeta` and `vbmeta_system` of `R870XXS2JZG3` (for example with Brokkr: `brokkr --wireless -a <tar>`).
