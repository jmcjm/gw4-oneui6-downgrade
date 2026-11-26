# Verified state

Device: Samsung Galaxy Watch 4 (SM-R870), bootloader `R870XXS2JZG3` (binary revision 2), unlocked, orange state. Recovery: [gw4-wifi-recovery](https://github.com/jmcjm/gw4-wifi-recovery) v6.

## What works and what does not

| Item | State |
|---|---|
| Boot to the One UI 6 Watch face (`R870XXU1IYI1`, Android 14, kernel `4.19.325-cip137-st21` from gw4-kernel-4.19) | works |
| Metadata encryption and file-based encryption of `/data`, KeyMint, gatekeeper | works (JZG3 trustlets) |
| Display | works; boot splash about 1 s after power-on (kernel change `0009`), until the boot animation |
| Charging (wireless, `p9222`) | works |
| Wi-Fi | works, `wlan0` gets an address; ADB over TCP on port 5555 with key authentication through the `adb-wifi-keep` module |
| Magisk 31.1 | works, `su` in the ADB shell; also a Magisk 31.1 build of our own (`31.1-wear`), put in with `build.sh magisk` |
| Both CPU cores | work: CPU1 starts at boot, CPU hotplug powers it off (`CLUSTER0_CPU1_STATUS` 0) and back on with PSCI `CPU_ON` |
| CPU idle C2 (core power-down) | works on both cores at the same time |
| System sleep (suspend to RAM) with both cores | works: CPU1 powered off by `CPU_OFF`, `EXYNOS-PM: MIF down`, `apsoc_count` rises, no early wakeup |
| Length of system sleep | normal: periods of up to 45 s between PMIC alarm wakeups (`s2mpw03-irq`). An open ADB connection from a computer wakes the SoC after 0 to 1 s every time (the computer's TCP ACKs on port 5555 raise the Wi-Fi host wake, `bcmsdh_sdmmc`), so measure sleep with `adb` disconnected |
| Bluetooth, pairing with a phone (required for the first setup) | works |
| Sensors, Samsung Health | work (checked on the watch) |
| GPS (`S.LSI SPOTNAV_4.12.0`) | works: 60 fixes in 60 attempts over 150 s with GPSTest, GPS, GLONASS, BeiDou and Galileo used in the fix, time to first fix 98.8 s cold and 2.1 s warm, mean accuracy 18.5 m indoors; no L5 |
| Charge limit (`batt_full_capacity`, kernel change `0008`) | works on the wireless pad: charging stops at the limit (`Not charging`, `batt_misc_event` `0x01000000`, current about 0 mA), resumes at the limit minus `batt_full_capacity_hyst` and stops again; values out of range are rejected; `100` ends the limit |

Checked on 2026-11-23 with `boot.img` `a34f6774…`: C2 entry counts of both cores keep rising, a CPU1 hotplug cycle reads `CLUSTER0_CPU1_STATUS` 0 while the core is offline, and off the charger with the screen off and no ADB connection the watch slept 183 s of about 3 minutes in 8 suspend cycles, each with `MIF down`. The charge limit was checked the same day with a build of patches `0001` to `0008`, the power symbol splash with `boot.img` `8038ee4d…` (patches `0001` to `0009` before the splash took an image), and the splash with a custom image with the locally built variant described below the hashes (boot, display, Wi-Fi, Magisk and ADB were checked with both; sleep and C2 were not measured again). Sensors, Samsung Health and GPS were checked on 2026-11-24 with the locally built variant; GPS through `dumpsys location` (GNSS KPIs) and `logcat` while GPSTest 3.10.6 held a location request.

All of the above was checked with the Samsung 4.19.151 kernel and the patches `0001` to `0009`. The kernel is now gw4-kernel-4.19 (Samsung 4.19.151 merged with CIP `v4.19.325-cip137`, with the same nine changes). With it, on 2026-11-27, with the locally built variant below: boot, display, both cores online, Wi-Fi, Magisk, the charge limit node, the sensor hub (22 IIO devices) and the memlogger work, and `dmesg` has no warning that the 4.19.151 kernel does not also have (`Unbalanced IRQ 175 wake disable`, the touch controller). Sleep, C2, GPS, the sensors and Samsung Health have not been checked again with this kernel.

## Hashes

Inputs:

| File | SHA-256 |
|---|---|
| `boot.img` of `R870XXU1IYI1` (from the AP) | `08a87664e6be9726479cdfd40cd15634133f6a3f34ed20bd4624590791dfc613` |
| the same, patched with the Magisk 31.1 app | `6918cec401dfb96991490bcf2f9776c7c9af098dcda281925f0944bc5a63b6c7` |
| `super` of `R870XXU1IYI1` (raw) | `7191adb9b7d2c7ff7b82d6f9ca7f6895e00ca86abab91e544011482e5fd77fe9` |
| `metadata` of `R870XXU1IYI1` (raw) | `67fa871fa038745029b7eec7a8a6cb5c4c36157befa4addae2311f8795dfd505` |
| `userdata` of `R870XXU1IYI1` (raw) | `fe55c2c0d71663429e8d5f964ecfafe81f55b6e27ac10a92808186c9af014426` |
| Kernel source (gw4-kernel-4.19 commit) | `kernel/source.txt` |
| JZG3 trustlets | `overlay/trustlets-R870XXS2JZG3.sha256` |

Outputs of `build.sh images`:

| File | SHA-256 |
|---|---|
| `dtbo.img` | `0175b41b121c3abd0ba72fbab625cb37e0ec93e5fe874b88102ebcf9c8662724` |
| `vbmeta.img` | `c2aa2079e68ebe788e04602c482288090f1f3ca62c71cff51a024503c8857153` |
| `vbmeta_system.img` | `8d1d1df7ddb62bacaa15ade994f23749fd520e64d20526e76a34c9dab62c323f` |
| `Image` (kernel, `build.sh kernel` without `BOOT_SPLASH`) | `e77f4266f890f0eb887407e26d900967d564edd3a1d5e065bc68ecd8a7dc6fe7` |
| `boot.img` | `8a5fef36901489be3307d26b57da908f1797d7e4e970bbd68c06ccc5c5ea0f60` |

These are the outputs of the default build from this repository, with the power symbol as the boot splash. `dtbo`, `vbmeta` and `vbmeta_system` are byte for byte the images that were flashed and booted. `boot.img` depends on the Magisk APK given to `build.sh magisk`: this one was built with a Magisk 31.1 build of our own (`31.1-wear`, APK SHA-256 `56e3b8d1464536029f3c94f4dfe8851c27a8f245d0dcd2b3fba452755c52cdf8`), whose patched image (`work/magisk_patched.img`) is `fef81502b185f62dc654ac69661a29bda591b4a4ef9a4f65027127aa1016aae7`.

The watch does not run this default `boot.img` byte for byte. It runs a variant built locally from the same sources and the same Magisk image, with a custom splash image given in `BOOT_SPLASH` (an image that is not part of this repository): `Image` `e59df6fb42fd52215ca5a5f6c587727eeac9c8ab5486d58a1c981f78eea9e416`, `boot.img` `31a830fd43a3fa082539dbc5fd0f4ccda7d967213195d55b18592612dae43003`. It differs from the default build only in the kernel, in the compressed image and the code that shows it; the ramdisk, the device tree and the other images are the same. `build.sh` fixes all embedded build times (initramfs, `__TIME__` in the Wi-Fi drivers, the banner), so its output does not depend on when it runs.

## SM-R860

An SM-R860 has run One UI 6 since 2026-11-26 with a build from before the CIP merge (kernel 4.19.151 with the patches `0001` to `0009`, custom splash). The build below, with gw4-kernel-4.19 (`r860-bl2`), made on 2026-11-27, **has not been booted yet**.

Inputs:

| File | SHA-256 |
|---|---|
| `boot.img` of `R860XXU1IYI1` (from the AP) | `6583e3a0b2d3f17c41f7c7e4c002814a0f0426298641a21998c15df7e2a7f65a` |
| `super` of `R860XXU1IYI1` (raw) | `281844a646e15e2cb9bb9d1dff5ec326a7c83c05bbbce467484e2975b8cc672e` |
| JZG3 trustlets | `overlay/trustlets-R860XXS2JZG3.sha256` |
| `work-R860/magisk_patched.img` (Magisk `31.1-wear`, the APK above) | `bc76016a019a080aa75021d4aa875b949fbc97eb63197857c45d58d5943870f9` |

Outputs of `build.sh images`:

| File | SHA-256 |
|---|---|
| `Image` (`exynos5515-freshbs_defconfig`, no `BOOT_SPLASH`) | `ac722be3e90e62cc88773247343e13c5a8c13059d9973f7a2049b687a4b50cc2` |
| `boot.img` | `533bd5356511b7d48827c18aeda6db71b298561f82adff55d84e980d2f87f92b` |
| `dtbo.img` | `1b5907e52018f1cd557c56787b3a8b5a99cd72a73a566d05096f2666ada1a493` |
| `vbmeta.img` | `c1b1fe3e1af1d42ad2cfb95d1b501796603906ee4ab2598d21f2778d9efe79b5` |
| `vbmeta_system.img` | `d22b97393d01b8a14f604ac5540113e2530db10cdffb1d7c1bb1a4855f3001d8` |

Before the CIP merge, the kernel `.config` equalled the one in the stock `R860XXU1IYI1` kernel except for the hypervisor clients (`kernel/nouh.config`) and `CONFIG_EXYNOS_DECON_BOOT_SPLASH`. The CIP merge adds the options of the later stable releases, with their defaults.

## Partition sizes

The same on the SM-R870 and the SM-R860 (identical PIT).

| Partition | Bytes |
|---|---|
| `boot` | 37 748 736 |
| `dtbo` | 8 388 608 |
| `vbmeta`, `vbmeta_system` | 524 288 |
| `metadata` | 33 554 432 |
| `super` | 5 368 709 120 |
| `userdata` | 8 942 256 128 (the factory f2fs uses 2 GiB of it) |
