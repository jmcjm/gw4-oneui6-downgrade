# Building and flashing

## Before you start

- **Bootloader unlocked**, watch on One UI 8 Watch `R870XXS2JZG3` with Magisk.
- **[gw4-wifi-recovery](https://github.com/jmcjm/gw4-wifi-recovery) installed** on the recovery partition. All flashing below happens from it, and it is the way back when One UI 6 does not boot. It has its own kernel and device tree, so it keeps working whatever is in `boot`.
- **A backup of the One UI 8 partitions** (step 1). Going back means writing them again.
- **Charged battery.** `super` is 5 GiB and goes over 2.4 GHz Wi-Fi at about 5.5 MB/s.

Host tools: `podman`, `curl`, `unzip`, `tar`, `git`, `lz4`, `simg2img`, `lpunpack`, `debugfs` (e2fsprogs), `python3`, `adb`. On Fedora: `android-tools e2fsprogs lz4 podman`.

## SM-R860

The same steps build One UI 6 `R860XXU1IYI1` for an SM-R860 (40 mm) on `R860XXS2JZG3`. Set `MODEL=R860` for every `build.sh` call; the work directory is then `work-R860/` and the inputs are the R860 ones:

```bash
export MODEL=R860
./build.sh source
./build.sh kernel
./build.sh firmware AP_R860XXU1IYI1_..._meta_WATCH_OS14.tar.md5
./build.sh trustlets <R860XXS2JZG3 super or vendor image>
./build.sh magisk Magisk-v31.1.apk
./build.sh images work-R860/magisk_patched.img
```

`MODEL` changes four things: the kernel source is the `r860-bl2` branch of gw4-kernel-4.19 (`kernel/source.txt`), the kernel is built from `exynos5515-freshbs_defconfig`, the trustlets are checked against `overlay/trustlets-R860XXS2JZG3.sha256`, and `BOOT_SPLASH_SIZE` defaults to the 396x396 panel. Everything else is shared, because it is the same on both watches: the PIT (partition numbers and sizes, so also `PREINITDEVICE`), the SoC device tree in `boot` (byte for byte, in IYI1 and in JZG3), the names of the JZG3 trustlets (only their signatures differ), the two modules in `/lib/modules`, and the kernel code (the two branches differ only in the SM-R870 device tree and defconfig). The two defconfigs differ in `CONFIG_SENSORS_SSP_HRM_ADI` only. The board device tree comes with the stock R860 `dtbo`.

Flashing and the way back work as below, with the R860 images and an R860 backup. The R860 build has not been booted yet (`STATUS.md`).

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

## 3. Kernel

```bash
./build.sh tools Magisk-v31.1.apk   # x86_64 magiskboot -> tools/
./build.sh toolchain                # AOSP clang-r383902 and binutils 2.27, ~400 MB
./build.sh source                   # kernel source, the pinned commit only (~200 MB)
./build.sh kernel                   # in a Debian bookworm container
```

`source` fetches the commit pinned in `kernel/source.txt` from [gw4-kernel-4.19](https://github.com/jmcjm/gw4-kernel-4.19), without history, to `work/kernel`: the `r870-bl2` branch for the SM-R870, `r860-bl2` for the SM-R860. That repository holds the Samsung 4.19.151 source (`R860XXU1IXK1` with the SM-R870 device tree and the `IYI1` update) merged with CIP `v4.19.325-cip137`, the 4.19.325 stable releases and the CIP backports after the end of 4.19.y, and on the `-bl2` branches the kernel changes for bootloader rev2, the charge limit and the boot splash, each as its own commit. The kernel reports `4.19.325-cip137-st21`.

`kernel` builds `exynos5515-freshbl_defconfig` with the options in `kernel/nouh.config` disabled. The host programs of the 4.19 tree do not build with current OpenSSL and without libyaml, hence the container. The banner values (`KBUILD_BUILD_*` in `build.sh`) are fixed, so the result is byte for byte the kernel whose hash is in `STATUS.md`.

### Charge limit

The `battery_v2` commit adds the charge limit of later Samsung battery drivers to `/sys/class/power_supply/battery/`, under the same name:

| Node | Values | Default |
|---|---|---|
| `batt_full_capacity` | `50` to `99`: stop charging at this capacity; `0` or `100`: no limit | `100` |
| `batt_full_capacity_hyst` | `1` to `20`: resume charging when the capacity has fallen by this much below the limit | `2` |

Both are written by root at runtime and are not kept across reboots; other values are rejected with `EINVAL`. The driver checks the limit in its own monitor work, so no process has to run for it. At the limit it votes the charger off and puts the wireless receiver in power hold mode, as at the end of a normal full charge, so the watch runs from the battery until charging resumes; `status` reads `Not charging` and `batt_misc_event` has bit `0x01000000` set. Lifting the watch off the pad or writing `100` ends the limit at once.

Test after flashing a boot image built with it, in a root shell (`adb shell`, then `su`), with the watch charging at between 50 and 99 %:

```bash
cd /sys/class/power_supply/battery
cat batt_full_capacity batt_full_capacity_hyst   # 100 2: no limit
cat capacity > batt_full_capacity                # limit at the current capacity
cat status batt_misc_event                       # Not charging; 16777216 (0x01000000) is set
dmesg | grep sec_bat_check_full_capacity         # stop charging (NN >= NN)
echo 100 > batt_full_capacity                    # no limit again: status back to Charging
```

With a limit above the current capacity, watch `capacity` and `status` while it charges: `Not charging` at the limit, `Charging` again at limit minus `batt_full_capacity_hyst`.

### Boot splash

Bootloader rev2 blanks the panel before it starts the kernel, and the MCD panel path of the display driver sends nothing to it until the first frame of the boot animation, about 20 s later. The `decon` boot splash commit draws a power symbol into the display framebuffer and sends it to the panel once, at the end of the display controller probe, about 1 s after power-on. The panel keeps the image in its own memory until SurfaceFlinger sends the next frame.

The splash is `CONFIG_EXYNOS_DECON_BOOT_SPLASH` (on by default). To build without it, add a line `EXYNOS_DECON_BOOT_SPLASH` to `kernel/nouh.config`.

An image can replace the power symbol. Give `build.sh kernel` a raw RGB565 file (little endian, the panel size: 450x450 and 405 000 bytes on the R870, 396x396 and 313 632 bytes on the R860) in `BOOT_SPLASH`:

```bash
BOOT_SPLASH=splash.rgb565 ./build.sh kernel
```

`build.sh` compresses it with zlib into `decon_boot_splash_image.h` in the kernel source; the driver inflates it into the framebuffer at probe and shows it as an RGB565 window. Without `BOOT_SPLASH` the header is removed and the power symbol is drawn. If the image is a frame of the boot animation (the same RGB565 pixels), the animation continues from the splash without a visible change. `BOOT_SPLASH_SIZE` (default: the panel size of `MODEL`) gives other sizes; an image that does not match the panel falls back to the power symbol. A kernel built with an image differs from the one whose hash is in `STATUS.md`.

## 4. Firmware, trustlets, Magisk boot image

```bash
./build.sh firmware AP_R870XXU1IYI1_..._meta_WATCH_OS14.tar.md5   # -> work/fw/
./build.sh trustlets backup-JZG3/super.img                       # -> work/trustlets/
./build.sh magisk Magisk-v31.1.apk                               # -> work/magisk_patched.img
```

`trustlets` takes the `vendor` partition out of the super image (or a vendor image directly), copies `/tee` and checks the files against `overlay/trustlets-R870XXS2JZG3.sha256`.

`magisk` patches `work/fw/boot.img` on this computer with the `boot_patch.sh` and the binaries from the APK given (the `armeabi-v7a` ones for the watch, override with `MAGISK_ABI`), with the options the Magisk app chooses on the watch (`KEEPFORCEENCRYPT=true`, `KEEPVERITY=false`, pre-init storage `mmcblk0p33`, override with `PREINITDEVICE`). It also takes a Magisk build of your own. With Magisk 31.1 the image is the one **Install → Select and Patch a File** in the app made, `6918cec4…` (`STATUS.md`), padded with zeros to the partition size.

## 5. Images

```bash
./build.sh images work/magisk_patched.img   # -> work/images/
```

| Output | Built from |
|---|---|
| `boot.img` | the Magisk-patched IYI1 image with the 4.19 kernel from step 3 (Magisk's DEFEX hexpatch, gzip), the IYI1 device tree adapted by `scripts/patch-dts.py` (the two nodes for the bootloader overlay, the second core's MPIDR and `cpu-map`, the rev2 `exynos-cpupm` node), and in the ramdisk the overlay with the JZG3 trustlets, the rebuilt kernel modules and a trigger that starts the boot animation right after SurfaceFlinger |
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
