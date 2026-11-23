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
| Sensors (heart rate, GPS), Samsung Health | not checked |
| Charge limit (`batt_full_capacity`, kernel patch `0008`) | works on the wireless pad: charging stops at the limit (`Not charging`, `batt_misc_event` `0x01000000`, current about 0 mA), resumes at the limit minus `batt_full_capacity_hyst` and stops again; values out of range are rejected; `100` ends the limit |

Checked on 2026-11-23 with `boot.img` `a34f6774…`: C2 entry counts of both cores keep rising, a CPU1 hotplug cycle reads `CLUSTER0_CPU1_STATUS` 0 while the core is offline, and off the charger with the screen off and no ADB connection the watch slept 183 s of about 3 minutes in 8 suspend cycles, each with `MIF down`. The charge limit was checked the same day with a build of patches `0001` to `0008`, the boot splash with the `boot.img` listed below (boot, display, Wi-Fi, Magisk and ADB were checked with it as well; sleep and C2 were not measured again).

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
| `Image` (kernel, `build.sh kernel`, patches `0001` to `0009`) | `da0f284b0d0fdf523f9c152e409ba2beb999ef93ad479244d8fe25b977189df1` |
| `boot.img` | `8038ee4d5bda666be25664a3c79dfe201a34d1db723f7a55650175cee2429ed7` |

`dtbo`, `vbmeta`, `vbmeta_system` and `boot` are byte for byte the images that were flashed and booted. `boot.img` depends on the Magisk APK given to `build.sh magisk`: this one was built with a Magisk 31.1 build of our own (`31.1-wear`, APK SHA-256 `66fb758f1b4a378a78cac132236a3aca42a30f942cd5510e3ea231677b69eb5f`), whose patched image (`work/magisk_patched.img`) is `97fcd3948bc61703b2acbc0b8bd984cca08b8258c3aeca821dcf45ee2291357d`. `build.sh` fixes all embedded build times (initramfs, `__TIME__` in the Wi-Fi drivers, the banner), so its output does not depend on when it runs.

## Partition sizes

| Partition | Bytes |
|---|---|
| `boot` | 37 748 736 |
| `dtbo` | 8 388 608 |
| `vbmeta`, `vbmeta_system` | 524 288 |
| `metadata` | 33 554 432 |
| `super` | 5 368 709 120 |
| `userdata` | 8 942 256 128 (the factory f2fs uses 2 GiB of it) |
