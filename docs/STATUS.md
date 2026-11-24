# Verified state

Device: Samsung Galaxy Watch 4 (SM-R870), bootloader `R870XXS2JZG3` (binary revision 2), unlocked, orange state. Recovery: [gw4-wifi-recovery](https://github.com/jmcjm/gw4-wifi-recovery) v6.

## What works and what does not

| Item | State |
|---|---|
| Boot to the One UI 6 Watch face (`R870XXU1IYI1`, Android 14, kernel 4.19.151) | works |
| Metadata encryption and file-based encryption of `/data`, KeyMint, gatekeeper | works (JZG3 trustlets) |
| Display | works; boot splash about 1 s after power-on (patch `0009`), until the boot animation |
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
| Charge limit (`batt_full_capacity`, kernel patch `0008`) | works on the wireless pad: charging stops at the limit (`Not charging`, `batt_misc_event` `0x01000000`, current about 0 mA), resumes at the limit minus `batt_full_capacity_hyst` and stops again; values out of range are rejected; `100` ends the limit |

Checked on 2026-11-23 with `boot.img` `a34f6774…`: C2 entry counts of both cores keep rising, a CPU1 hotplug cycle reads `CLUSTER0_CPU1_STATUS` 0 while the core is offline, and off the charger with the screen off and no ADB connection the watch slept 183 s of about 3 minutes in 8 suspend cycles, each with `MIF down`. The charge limit was checked the same day with a build of patches `0001` to `0008`, the power symbol splash with `boot.img` `8038ee4d…` (patches `0001` to `0009` before the splash took an image), and the splash with a custom image with the locally built variant described below the hashes (boot, display, Wi-Fi, Magisk and ADB were checked with both; sleep and C2 were not measured again). Sensors, Samsung Health and GPS were checked on 2026-11-24 with the locally built variant; GPS through `dumpsys location` (GNSS KPIs) and `logcat` while GPSTest 3.10.6 held a location request.

## Hashes

Inputs:

| File | SHA-256 |
|---|---|
| `boot.img` of `R870XXU1IYI1` (from the AP) | `08a87664e6be9726479cdfd40cd15634133f6a3f34ed20bd4624590791dfc613` |
| the same, patched with the Magisk 31.1 app | `6918cec401dfb96991490bcf2f9776c7c9af098dcda281925f0944bc5a63b6c7` |
| `super` of `R870XXU1IYI1` (raw) | `7191adb9b7d2c7ff7b82d6f9ca7f6895e00ca86abab91e544011482e5fd77fe9` |
| `metadata` of `R870XXU1IYI1` (raw) | `67fa871fa038745029b7eec7a8a6cb5c4c36157befa4addae2311f8795dfd505` |
| `userdata` of `R870XXU1IYI1` (raw) | `fe55c2c0d71663429e8d5f964ecfafe81f55b6e27ac10a92808186c9af014426` |
| Samsung kernel source packages | `kernel/sources.txt` |
| JZG3 trustlets | `overlay/trustlets-R870XXS2JZG3.sha256` |

Outputs of `build.sh images`:

| File | SHA-256 |
|---|---|
| `dtbo.img` | `0175b41b121c3abd0ba72fbab625cb37e0ec93e5fe874b88102ebcf9c8662724` |
| `vbmeta.img` | `c2aa2079e68ebe788e04602c482288090f1f3ca62c71cff51a024503c8857153` |
| `vbmeta_system.img` | `8d1d1df7ddb62bacaa15ade994f23749fd520e64d20526e76a34c9dab62c323f` |
| `Image` (kernel, `build.sh kernel` without `BOOT_SPLASH`, patches `0001` to `0009`) | `c2ff423d0511c1ac3907f053cbc7f807e121793d33fd40ee862dc1eddaca6e04` |
| `boot.img` | `b2d1cf641a26daa5c3ae45ccf536ab638c3bb6e4c499874544c8223a73c62833` |

These are the outputs of the default build from this repository, with the power symbol as the boot splash. `dtbo`, `vbmeta` and `vbmeta_system` are byte for byte the images that were flashed and booted. `boot.img` depends on the Magisk APK given to `build.sh magisk`: this one was built with a Magisk 31.1 build of our own (`31.1-wear`, APK SHA-256 `56e3b8d1464536029f3c94f4dfe8851c27a8f245d0dcd2b3fba452755c52cdf8`), whose patched image (`work/magisk_patched.img`) is `fef81502b185f62dc654ac69661a29bda591b4a4ef9a4f65027127aa1016aae7`.

The watch does not run this default `boot.img` byte for byte. It runs a variant built locally from the same sources and the same Magisk image, with a custom splash image given in `BOOT_SPLASH` (an image that is not part of this repository): `Image` `69d83d92489745face4f9f81b33084d2c3b9b2c3c49555d1c5324278eadba950`, `boot.img` `4698c41246f271e10e5a7a406254008b4fc4643fb5924c3497f40669bb6b25f8`. It differs from the default build only in the kernel, in the compressed image and the code that shows it; the ramdisk, the device tree and the other images are the same. `build.sh` fixes all embedded build times (initramfs, `__TIME__` in the Wi-Fi drivers, the banner), so its output does not depend on when it runs.

## Partition sizes

| Partition | Bytes |
|---|---|
| `boot` | 37 748 736 |
| `dtbo` | 8 388 608 |
| `vbmeta`, `vbmeta_system` | 524 288 |
| `metadata` | 33 554 432 |
| `super` | 5 368 709 120 |
| `userdata` | 8 942 256 128 (the factory f2fs uses 2 GiB of it) |
