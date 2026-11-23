# Verified state

Device: Samsung Galaxy Watch 4 (SM-R870), bootloader `R870XXS2JZG3` (binary revision 2), unlocked, orange state. Recovery: [gw4-wifi-recovery](https://github.com/jmcjm/gw4-wifi-recovery) v6.

## What works and what does not

| Item | State |
|---|---|
| Boot to the One UI 6 Watch face (`R870XXU1IYI1`, Android 14, kernel 4.19.151) | works |
| Metadata encryption and file-based encryption of `/data`, KeyMint, gatekeeper | works (JZG3 trustlets) |
| Display | works |
| Charging (wireless, `p9222`) | works |
| Wi-Fi | works, `wlan0` gets an address; ADB over TCP on port 5555 after boot (`overlay.d/adb-tcp.rc`) |
| Magisk 31.1 | works, `su` in the ADB shell |
| Both CPU cores | work: CPU1 starts at boot, CPU hotplug powers it off (`CLUSTER0_CPU1_STATUS` 0) and back on with PSCI `CPU_ON` |
| CPU idle C2 (core power-down) | works on both cores at the same time |
| System sleep (suspend to RAM) with both cores | works: CPU1 powered off by `CPU_OFF`, `EXYNOS-PM: MIF down`, `apsoc_count` rises, no early wakeup |
| Length of system sleep | normal: periods of up to 45 s between PMIC alarm wakeups (`s2mpw03-irq`). An open ADB connection from a computer wakes the SoC after 0 to 1 s every time (the computer's TCP ACKs on port 5555 raise the Wi-Fi host wake, `bcmsdh_sdmmc`), so measure sleep with `adb` disconnected |
| Bluetooth, pairing with a phone (required for the first setup) | works |
| Sensors (heart rate, GPS), Samsung Health | not checked |

Checked on 2026-11-23 with `boot.img` `a34f6774…`: C2 entry counts of both cores keep rising, a CPU1 hotplug cycle reads `CLUSTER0_CPU1_STATUS` 0 while the core is offline, and off the charger with the screen off and no ADB connection the watch slept 183 s of about 3 minutes in 8 suspend cycles, each with `MIF down`.

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
| `Image` (kernel, `build.sh kernel`) | `d3c20d57dd33cbc7296e3f98b9de1d911491662a26663f35339a718e4e47d9de` |
| `boot.img` | `a34f6774701c57d6a6a320f5646488f03455cdf03769aada513388aee87c89d0` |

`dtbo`, `vbmeta`, `vbmeta_system` and `boot` are byte for byte the images that were flashed and booted. `build.sh` fixes all embedded build times (initramfs, `__TIME__` in the Wi-Fi drivers, the banner), so its output does not depend on when it runs.

## Partition sizes

| Partition | Bytes |
|---|---|
| `boot` | 37 748 736 |
| `dtbo` | 8 388 608 |
| `vbmeta`, `vbmeta_system` | 524 288 |
| `metadata` | 33 554 432 |
| `super` | 5 368 709 120 |
| `userdata` | 8 942 256 128 (the factory f2fs uses 2 GiB of it) |
