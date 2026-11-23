# License

Copyright (C) 2026 Jakub Mendyka

This project is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 2 of the License, or (at your option) any later version. The full text of version 2 is in `COPYING`.

SPDX-License-Identifier: `GPL-2.0-or-later`

This covers everything in this repository unless a section below says otherwise.

## Kernel patches

The files in `kernel/patches/` modify the Linux kernel source released by Samsung, which is licensed under the GNU General Public License, version 2 only. The patches are derived from it and are distributed under the same terms (`GPL-2.0-only`).

## Third-party material not in this repository

The build combines this project with files that are not part of it and are not covered by this license:

- **Samsung firmware**: the One UI 6 Watch images (`R870XXU1IYI1`) and the TEE trustlets taken from the One UI 8 Watch vendor partition (`R870XXS2JZG3`) belong to Samsung Electronics and its suppliers. The repository holds none of them, only checksums. You provide the firmware, and the built `boot.img` contains Samsung trustlets and the Samsung ramdisk, so built images must not be redistributed.
- **The Samsung kernel source** is downloaded from [opensource.samsung.com](https://opensource.samsung.com) under the GNU General Public License, version 2.
- **The AOSP toolchain** (`clang-r383902`, `aarch64-linux-android-4.9`) is downloaded from [android.googlesource.com](https://android.googlesource.com) under its own licenses.
- **Magisk** ([topjohnwu/Magisk](https://github.com/topjohnwu/Magisk), GNU General Public License, version 3): `magiskboot` is extracted from a Magisk APK you provide and runs as a separate program during the build, and the boot image you patch with Magisk contains its ramdisk. Neither is stored here.

Samsung, Galaxy, Galaxy Watch and One UI are trademarks of Samsung Electronics Co., Ltd. This project is not affiliated with, endorsed by or supported by Samsung or Google.

## No warranty

This software is provided without any warranty, as described in sections 11 and 12 of the GNU General Public License, version 2. In particular:

- It replaces the system of the watch with an older one on a newer bootloader, with a modified kernel, unsigned images and trustlets from another firmware version. The watch can end up unable to boot. The way back described in `docs/BUILDING.md` needs a working recovery with root over Wi-Fi or Wireless Download.
- Flashing wipes user data.
- Unlocking the bootloader trips Knox permanently and may void the manufacturer's warranty.

You use it at your own risk.
