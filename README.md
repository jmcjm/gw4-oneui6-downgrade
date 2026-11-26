# Galaxy Watch 4 (SM-R870, SM-R860): One UI 6 Watch on a One UI 8 bootloader

Runs One UI 6 Watch (`R870XXU1IYI1`, Android 14, kernel 4.19) on a Samsung Galaxy Watch 4 (SM-R870) that has already been updated to One UI 8 Watch (`R870XXS2JZG3`).

The same build, with `MODEL=R860`, makes the images for the 40 mm SM-R860 (`R860XXU1IYI1` on `R860XXS2JZG3`); they are built but not yet booted (`docs/BUILDING.md`, section SM-R860).

Samsung does not allow this. The One UI 8 update raises the bootloader binary revision from 1 to 2, the revision is enforced by an eFuse counter, and every One UI 6 image is signed for revision 1. Flashing stock One UI 6 through Odin or NetOdin is refused. With an unlocked bootloader the old system can still run on the new bootloader, together with the TEE, the hypervisor and the power management firmware that come with it, after fixing eleven incompatibilities between them.

**Status: boots and runs on both CPU cores, with CPU idle power-down and system sleep working.** Bluetooth, phone pairing, the sensors, Samsung Health and GPS work. Details in `docs/STATUS.md`.

## What had to change

| Problem on bootloader rev2 | Fix |
|---|---|
| Images signed for rev1 are rejected (`CHECK FAIL ... DEVICE: 2, BINARY: 1`) | Samsung signature footer removed from `vbmeta`, `vbmeta_system`, `dtbo`; `vbmeta` flags `3` |
| The bootloader's own device tree overlay needs labels the 4.19 tree lacks (`DT Overlay FAIL`) | two disabled `debug_snapshot` nodes added to the device tree |
| A raw kernel image is not decompressed, the bootloader jumps into garbage | kernel gzipped |
| The APM firmware has an interrupt pending before the driver is ready (NULL dereference in `acpm_ipc`) | kernel patch: request the interrupt at the end of probe |
| TEEgris rejects the One UI 6 trustlets (`TA_PKG: model name does not match`), so `/data` never mounts | One UI 8 trustlets bind-mounted over `/vendor/tee` at boot |
| The panel is handed over asleep with TE off, the display driver panics on the first frame | kernel patch: always run the panel init sequence |
| The Wi-Fi module on the system partition was built for the stock kernel | modules built with this kernel bind-mounted over `/lib/modules` |
| The second core has MPIDR `0x100`, the 4.19 device tree says `0x1`; `CPU_ON` wakes nothing | device tree: `cpu@0001` reg `0x100` and a `cpu-map` |
| EL3 powers no core down (C2 fails, `CPU_OFF` returns) until the kernel sends `SMC_CMD_CPUPM_ENABLE`, which 4.19 never does | kernel patches: the 5.15 exynos-cpupm driver ported to 4.19, the core `INT_EN` writes dropped; device tree: the rev2 `exynos-cpupm` node |
| With real MPIDRs in the device tree, the 4.19 `sleep.S` gives both cores the same saved-context slot, and both cores in C2 hang the system | kernel patch: hash the MPIDR as it is, as mainline does |
| The bootloader blanks the panel before the kernel starts, so the screen stays black for about 20 s until the boot animation; it also leaves its own display window enabled with an address the kernel's SysMMU does not map | kernel patch: a boot splash sent once at probe, with every other display window disabled first |

The kernel is [gw4-kernel-4.19](https://github.com/jmcjm/gw4-kernel-4.19): Samsung's 4.19 source for `R870XXU1IYI1` merged with the CIP 4.19 kernel (`4.19.325-cip137`, the stable releases up to 4.19.325 and the CIP backports after them), with seven changes for the rev2 bootloader, an eighth that adds a charge limit (`batt_full_capacity`, off by default) and a ninth that shows a boot splash on the blank panel. It is built without the Samsung hypervisor clients (UH, RKP, KDP): the KDP interface of the rev2 hypervisor changed, and its RKP expects the 5.15 kernel memory layout. Each problem, with the log lines that showed it, is described in `docs/LESSONS.md`.

The boot image does not open ADB over TCP. For ADB on a fixed port, with key authentication, use the `adb-wifi-keep` module from [gw4-magisk-modules](https://github.com/jmcjm/gw4-magisk-modules): it keeps Wi-Fi on and adbd on TCP 5555 after every boot and authorizes the keys it ships.

The system partitions (`super`, `metadata`, `userdata`) are the stock One UI 6 ones. Everything that changes is in `boot`: the kernel, the device tree, and a Magisk `overlay.d` in the ramdisk that puts the trustlets and modules in place before the services that need them start, and starts the boot animation right after SurfaceFlinger.

## Requirements

- Galaxy Watch 4 SM-R870 on `R870XXS2JZG3` with an unlocked bootloader and Magisk.
- [gw4-wifi-recovery](https://github.com/jmcjm/gw4-wifi-recovery) on the recovery partition: all flashing goes through it, and it is the way back.
- The `R870XXU1IYI1` firmware, a Magisk APK, a Linux computer with podman.

## Usage

```bash
./build.sh tools Magisk-v31.1.apk
./build.sh toolchain
./build.sh source
./build.sh kernel
./build.sh firmware AP_R870XXU1IYI1_..._meta_WATCH_OS14.tar.md5
./build.sh trustlets backup-JZG3/super.img
./build.sh magisk Magisk-v31.1.apk
./build.sh images work/magisk_patched.img
```

Then flash from the Wi-Fi recovery with `scripts/flash-chunks.sh`. Backup, the Magisk step, flashing, and the way back to One UI 8 are in `docs/BUILDING.md`.

## Repository layout

| Path | Contents |
|---|---|
| `build.sh` | All build steps |
| `kernel/source.txt` | The kernel source for each model: the gw4-kernel-4.19 branch and pinned commit |
| `kernel/nouh.config` | Options disabled in `exynos5515-freshbl_defconfig` |
| `overlay/` | Magisk `overlay.d` scripts and the expected trustlet hashes |
| `scripts/` | Signature stripping, device tree patch, chunked flashing |
| `docs/` | Building and flashing, verified state, lessons learned |

Not in the repository: firmware, trustlets, kernel source, toolchains, built images. They contain Samsung or third-party material; the build fetches or extracts them, and `work/` and `tools/` are ignored.

## Limitations

- While a computer keeps an ADB connection open, the watch wakes from system sleep within a second; disconnect `adb` when the battery matters.
- `/data` is the 2 GiB factory f2fs; the partition is larger.
- Only `R870XXU1IYI1` on bootloader `R870XXS2JZG3` has been booted. The SM-R860 build is untested.
- Over-the-air updates must not be installed; they would bring back a signed rev2 system.

## License

GPL-2.0-or-later; the kernel (gw4-kernel-4.19) is GPL-2.0-only. See `LICENSE.md` and `COPYING`. Built images contain Samsung firmware and must not be shared.
