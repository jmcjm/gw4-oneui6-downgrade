# Lessons learned

One UI 6 Watch (`R870XXU1IYI1`, Android 14, kernel 4.19) was built for bootloader binary revision 1. A watch updated to One UI 8 Watch (`R870XXS2JZG3`) has a revision 2 bootloader, which cannot be downgraded (the revision is enforced by an eFuse counter). Everything below runs the old system on that new bootloader, together with the TEE, the hypervisor and the power management firmware that come with it.

Each problem was found from the bootloader and kernel log in `/proc/last_kmsg`, read from a recovery with root over Wi-Fi ([gw4-wifi-recovery](https://github.com/jmcjm/gw4-wifi-recovery)). That recovery has its own kernel and device tree, so it kept working through every failed boot.

## 1. Signed rev1 images are rejected

Flashing the stock `boot`, `dtbo`, `vbmeta` and `vbmeta_system` of `R870XXU1IYI1` ends in the bootloader with:

```
CHECK FAIL ... DEVICE: 2, BINARY: 1
```

Samsung appends a footer to each image: `SignerVer03`, the firmware version (`R870XXU1IYI1`, whose fifth character is the binary revision) and the key name. The bootloader reads the revision from it. Changing the `vbmeta` flags alone does not help.

Fix: cut the image to the length its own header declares (`256 + auth + aux` for vbmeta, `total_size` of the `dt_table` for dtbo) and pad it with zeros. Without the footer the image counts as a custom binary, which an unlocked bootloader boots in the orange state. `vbmeta` additionally gets flags `3` (hashtree and verification disabled). `scripts/strip-signature.py` does this.

## 2. The bootloader applies its own device tree overlay

With unsigned images the bootloader stops in Odin mode:

```
[UFDT] DT Overlay FAIL
Couldn't find log_first symbol in main dtb
```

After the DTBO, the rev2 bootloader applies an overlay built into the bootloader itself (`debug_snapshot`, `memlogger` and `itmon` settings). It references the labels `log_first` and `log_kevents_small`, which exist in the 5.15 device tree but not in the 4.19 one.

Fix: add both nodes to `/reserved-memory/debug_snapshot` with `status = "no"` and add their `__symbols__` entries. `scripts/patch-dts.py` does this, together with the device tree changes of problems 8 and 9; the DTB is decompiled and compiled with the `dtc` 1.5.0 built together with the kernel.

## 3. The bootloader only boots a gzip-compressed kernel

The One UI 6 boot image has a raw `Image`. The rev2 bootloader logs

```
gzip header is not correct. Error!
```

and still jumps to the kernel load address, which holds whatever the previous boot left there. The result is an exception caught by the bootloader at a different address on every boot (`Alignment fault`, undefined instruction), or a hang that ends in the 60-second bootloader watchdog. The stock 4.19 kernel "hanging without a single log line" in the first attempts was this, not the kernel.

Fix: `gzip -9 -n` the kernel. `magiskboot repack` keeps an already compressed kernel as it is.

## 4. The APM firmware already has an interrupt pending

The 4.19 kernel then boots and panics at 1.1 s:

```
Unable to handle kernel NULL pointer dereference at virtual address 0000000000000028
pc : acpm_ipc_irq_handler+0x10/0x88
...
acpm_ipc_probe+0xd0/0x788
```

`acpm_ipc_probe` requests the interrupt before it maps the interrupt registers. With the rev2 APM firmware an interrupt is already pending, so the handler runs immediately and reads `NULL + INTSR1`. The 5.15 driver requests the interrupt at the end of probe. The shared SRAM layout (`struct acpm_framework`) is the same in both kernels for S5E5515.

Fix: `kernel/patches/0001-acpm_ipc-...` moves the request to the end of probe.

## 5. TEEgris rejects the One UI 6 trustlets

The system then gets to `init`, but stays on a black screen. The Secure OS that comes with the bootloader (TEEgris 4.2.0.0) checks that each trustlet was signed for the running firmware:

```
TA_PKG: model name does not match R870XXS2JZG3, cert : R870XXU1IYI1
Failed to verify TA image ... UUID = 00000000-0000-0000-0000-4b45594d5354
```

Without the KeyMint trustlet `keystore2` never registers, `vold` cannot create the metadata encryption key, and `/data` is never mounted.

Fix: the eight files in `/vendor/tee` are replaced at boot with the ones from the `R870XXS2JZG3` vendor partition (same UUIDs). `tzdaemon` is the same binary in both versions, and the One UI 6 KeyMint HAL works with the newer KeyMint trustlet (`skeymint version: 400.0.11`). The trustlet logs `Device is compromized` on every operation; it is a warning, the operations succeed.

How the files are replaced matters:

- The ramdisk is patched by Magisk, so the files go into `overlay.d/sbin` and an `overlay.d/*.rc` script runs on `fs`, before `tzdaemon` starts on `post-fs`.
- A `mount ... bind` from the `init` domain fails with `EACCES`, without any `avc` line in the log. The bind mounts run from a script in the `u:r:magisk:s0` domain instead.
- `magisk --post-fs-data` relabels the whole Magisk tmpfs (`/debug_ramdisk`) to `system_file`. The gatekeeper HAL reads its trustlet file itself and was then denied. The script copies the files to `/dev/tee-jzg3` and labels them `u:object_r:tee_file:s0`, the label of `/vendor/tee` in the vendor `file_contexts`.

## 6. The panel is handed over asleep

With the TEE working, Android starts `system_server`, `surfaceflinger` and the boot animation, and the kernel panics one second later:

```
decon0 wait for vsync timeout
decon0 timeout of updating decon registers
PC is at decon_update_regs+0xa7c/0xa80
```

The panel (`rm69091`, id `0x413041`) reports `RDDPM 0x08`: normal mode, but sleep-in, display off and TE off. The rev2 bootloader initializes the panel with its own driver (`rm69091_watch4_large`) and shows the logo, but the 4.19 kernel finds it asleep. The kernel trusted the bootloader (`reset` GPIO high, so state `NORMAL`), skipped the init sequence and waited for a vsync that never came.

Fix: `kernel/patches/0002-mcd_panel-...` treats a panel left on by the bootloader as powered but not initialized, so the first sleep-out runs the full init sequence (TE on, sleep out, display on).

## 7. The system partition carries kernel modules

With the display working, One UI 6 boots to the watch face, but Wi-Fi finds no networks: there is no `wlan0`. The Wi-Fi driver is not built into the kernel. `macloader` (vendor) loads `/lib/modules/ifxdhd.ko` from the system partition, and the kernel rejects it:

```
ifxDhd: disagrees about version of symbol module_layout
macloader: finit_module for failed: Exec format error
```

The module was built for the stock kernel (`4.19.151-30937185-abR870XXU1IYI1`, symbol CRCs of the stock configuration). `/lib/modules` also has `lcd.ko`.

Fix: the build produces both modules for this kernel. `build.sh images` strips their debug info and puts them into the ramdisk; `overlay.d/kmod.rc` bind-mounts them over `/lib/modules/*.ko` on `fs`, labelled `u:object_r:rootfs:s0` like the originals. After that `ifxdhd` loads and `wlan0` gets an address.

## 8. The second core has a different MPIDR

With one core the watch was barely usable. PSCI `CPU_ON` for the second core succeeded, but the core never ran kernel code (`CPU1: failed to come online`). The 4.19 device tree gives it `reg = <0x0 0x1>`; on the rev2 bootloader its MPIDR is `0x100` (Aff1 = 1), as in the 5.15 device tree, and `CPU_ON(0x1)` wakes nothing.

Fix: `scripts/patch-dts.py` sets the `cpu@0001` reg to `0x100` and adds a `cpu-map` with both cores in one cluster; without it the kernel would put a core with Aff1 = 1 in a cluster of its own.

## 9. EL3 powers no core down until the kernel asks for it

With two cores running, the SoC still never reached system sleep: every attempt ended in `EXYNOS-PM: early wakeup` with `MIF blocked`, and `apsoc_count` stayed at 0, while `maxcpus=1` slept fine. PSCI `CPU_OFF` of the second core returned `PSCI_SUCCESS` without powering it down (the PMU still showed `CLUSTER0_CPU1_STATUS` 1), so the core kept the cluster awake. Every cpuidle C2 entry also failed: the usage counters of the C2 state stayed at 0 on both cores.

The rev2 EL3 runs CPU power-off sequences only after the kernel sends `SMC_CMD_CPUPM_ENABLE` (`0x82000008`, argument 1). The 5.15 exynos-cpupm driver does it at the end of probe (`notify_cpupm_init_to_el3()`); the 4.19 driver never does. The 5.15 driver also handles the power modes differently from 4.19 (selected by `cal-id`, the PSCI state is always `0x00010000`, SICD with other wakeup masks and an APM notification), and so does its device tree node.

Fix: `kernel/patches/0007-exynos-cpupm-...` ports the 5.15 driver, including the SMC at the end of probe, and `scripts/patch-dts.py` replaces the 4.19 `cpupm` node with the `exynos-cpupm` node of the rev2 device tree. A comparison of the cpuidle and hotplug paths of both kernels showed that the per-core PMU sequences, the PSCI calls and the GIC handling are otherwise the same. Confirmation that the firmware itself is fine came from the Wi-Fi recovery, which runs the 5.15 kernel on the same bootloader: there a CPU1 hotplug cycle and C2 on both cores work.

Two earlier patches belong here as well. `0003` drops the `CLUSTER0_CPUx_INT_EN` writes of the 4.19 PMU sequences, as 5.15 does; the rev2 EL3 sets these bits itself after `SMC_CMD_CPUPM_ENABLE`. `0004` reads the time with `ktime_get_mono_fast_ns()` in the cpupm idle path, which also runs during suspend to idle with timekeeping suspended. Patch `0005` (park a core whose `CPU_OFF` returns) dates from before this was understood. With `0007` `CPU_OFF` does power the core down and the parking path is not used; it stays as a fallback.

## 10. Both cores in C2 shared one saved context

With `SMC_CMD_CPUPM_ENABLE` sent, C2 worked on one core at a time, but with C2 on both cores the system hung within about 10 s, without a panic, until the watchdog reset it. Sending the SMC during boot therefore ended in a boot loop.

The Samsung 4.19 `arch/arm64/kernel/sleep.S` shifts a multithreading MPIDR right by 8 before it computes the `sleep_save_stash` index of the core, both when saving the context (`__cpu_suspend_enter`) and when restoring it (`_cpu_resume`). That matched the rev1 device tree (`0x0`, `0x1`). The hash mask is built from the device tree cpu reg values, which are now the real MPIDRs (`0x0`, `0x100`, problem 8), and the shifted MPIDR of both cores lands in the same slot. With both cores in C2, one resumed with the other's stack and page tables. The 5.15 `sleep.S` has no such shift. The hint came from a [kernel port for the Exynos 3830](https://github.com/rsuntk/android_kernel_samsung_exynos850-5.10/pull/2) that hit the mirror image of this problem (a 5.10 kernel on a 4.19-era EL3).

Fix: `kernel/patches/0006-arm64-sleep-...` uses the MPIDR as it is.

## 11. The bootloader leaves its own display window enabled

Bootloader rev2 blanks the panel before it starts the kernel (problem 6), and the MCD panel path of `decon_initial_display()` sends no frame: it expects the bootloader logo to stay on. The screen stayed black for about 20 s, until the first frame of the boot animation.

The first version of the boot splash (`0009`) drew into the decon framebuffer, set window 0 and DPP0 to it and sent one frame, the way the non-MCD path does. Every boot then panicked at 1.1 s:

```
decon_initial_display: boot splash
exynos-sysmmu 13820000.sysmmu: From [G0, G1, VG], SysMMU READ PAGE FAULT at 0x9e0cf000
Kernel panic - not syncing: (13820000.sysmmu) ... READ PAGE FAULT
```

The DECON register dump printed with the fault showed `DATA_PATH_CONTROL_0` `0x11` (windows 0 and 1 enabled) and `DATA_PATH_CONTROL_1` `0x10` (window 1 on channel 1). Window 1, full screen, was the bootloader's, with the physical address of its own buffer in DPP1, programmed while the DPU SysMMU was bypassed. In the kernel that SysMMU translates from probe on (`sysmmu,hold-rpm-on-boot`), and its page table maps only what the kernel mapped. Our window was fine: DPP0 read the framebuffer at IOVA `0x10000000`, and the SysMMU TLB held its pages. The frame fetched both windows, and every SysMMU page fault is fatal (`exynos_sysmmu_irq()` retries only page table walk errors). Without the splash the first frame comes from the HWC, which programs or disables every window first, so the leftover window is never fetched.

Fix: `kernel/patches/0009-decon-...` disables every window except the default one before it sends the frame.

## Hypervisor clients are disabled

The kernel is built without `CONFIG_UH`, `CONFIG_RKP` and `CONFIG_KDP`. The bootloader loads the Samsung hypervisor (uH) at EL2 anyway; the 4.19 kernel only never calls it.

- Between 4.19 and 5.15 the KDP interface changed: KDP moved from application id 2 (shared with RKP) to its own id 3, and every command number changed.
- RKP cannot work either: the rev2 uH has the 5.15 kernel memory layout built in (linear map at `0xffffff8000000000`, `phys_to_virt` as `pa - phys_offset + 0xffffff8000000000`), while 4.19 has the linear map in the upper half (`0xffffffc000000000`). A 4.19 kernel with RKP stops before its first log line. Running RKP would need the arm64 VA space flip of Linux 5.4 backported.

None of this is needed for power management: the uH image contains no PSCI function ids, and the problems of the second core were problems 8 to 10.

## Disproved on the way

- "Recovery takes its device tree from the boot partition": wrong. Recovery failed in the first attempts because of the rev1 signatures; it has its own DTB and boots whatever is in `boot`.
- "The stock 4.19 kernel hangs in the hypervisor": not shown. It was the raw kernel image (problem 3).
- "Unsigned images are fine once `vbmeta` has flags 3": not enough, the footer has to go (problem 1).
- "CPU_OFF needs a running RKP": wrong. uH does not trap SMC (it changes only `HCR_EL2.VM`) and has no PSCI code; problem 9 was the missing SMC.
- "Setting `CORE_PWRDN_EN` in `CPUPWRCTLR_EL1` before WFI powers the parked core down": no. The core stops answering, but FlexPMU never gets a power-down request and the core is lost.
- "Both cores in C2 hang because of the cluster or system power-down mode": no. SICD, CPD, the `psci-index` of the 4.19 device tree, the per-core timers and the APM `dsu_cpd` flag were ruled out one by one; it was problem 10.
- "The rev1 bootloader can be written back with `dd`": not tried, and not worth trying. The revision is in an eFuse and checked by the boot chain; an older boot chain would most likely leave the watch without Download mode.
