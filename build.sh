#!/usr/bin/env bash
# One UI 6 Watch (R870XXU1IYI1) on a Galaxy Watch 4 (SM-R870) whose
# bootloader is at binary revision 2 (R870XXS2JZG3, One UI 8 Watch).
#
# Steps, in order (see docs/BUILDING.md):
#
#   ./build.sh tools <Magisk APK>         x86_64 magiskboot -> tools/
#   ./build.sh toolchain                  AOSP clang-r383902 + binutils 2.27
#   ./build.sh source                     Samsung 4.19 source + patches
#   ./build.sh kernel                     build the kernel (in a container)
#   ./build.sh firmware <IYI1 AP tar.md5> unpack the One UI 6 images
#   ./build.sh trustlets <JZG3 image>     TEE trustlets from a JZG3 vendor
#                                         or super image
#   ./build.sh magisk <Magisk APK>        work/fw/boot.img patched with
#                                         Magisk -> work/magisk_patched.img
#   ./build.sh images <Magisk boot.img>   boot, dtbo, vbmeta, vbmeta_system
#
# Everything goes to work/ (override with WORK=...). The finished images
# are in work/images/, the One UI 6 partitions in work/fw/.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$here/work}
MAGISKBOOT=${MAGISKBOOT:-$here/tools/magiskboot}
BUILD_IMAGE=localhost/gw4-kbuild-bookworm:amd64

# Fixed build identity, so that the kernel build is reproducible: the
# banner, the initramfs timestamps and __DATE__/__TIME__ (used by the Wi-Fi
# drivers) all come from these values. The container has no git on
# purpose: with git, scripts/setlocalversion would append a commit hash.
export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-root}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-6453a2cb221b}
export KBUILD_BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP:-"Sun Nov 22 15:41:29 UTC 2026"}
export KBUILD_BUILD_VERSION=${KBUILD_BUILD_VERSION:-3}

CLANG_URL=https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android11-release/clang-r383902.tar.gz
GCC_URL=https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/+archive/refs/heads/android11-release.tar.gz
CLANG_BANNER='Android (6443078 based on r383902) clang version 11.0.1'
LD_BANNER='GNU ld (binutils-2.27-bd24d23f) 2.27.0.20170315'

# partition sizes on SM-R870 (bytes)
SIZE_BOOT=37748736
SIZE_DTBO=8388608
SIZE_VBMETA=524288

die() { echo "build.sh: $*" >&2; exit 1; }
need() { for c in "$@"; do command -v "$c" >/dev/null || die "$c is required"; done; }
need_magiskboot() {
    [[ -x $MAGISKBOOT ]] || die "magiskboot not found at $MAGISKBOOT (run ./build.sh tools <Magisk APK>)"
}

cmd_tools() {
    local apk=${1:?Magisk APK}
    need unzip
    mkdir -p "$here/tools"
    unzip -p "$apk" lib/x86_64/libmagiskboot.so > "$here/tools/magiskboot"
    chmod 755 "$here/tools/magiskboot"
    echo "tools/magiskboot extracted"
}

cmd_toolchain() {
    need curl tar
    local tc=$WORK/toolchains
    mkdir -p "$tc"
    if [[ ! -x $tc/clang-r383902/bin/clang ]]; then
        echo "downloading clang-r383902"
        mkdir -p "$tc/clang-r383902"
        curl -sSfL "$CLANG_URL" | tar xz -C "$tc/clang-r383902"
    fi
    if [[ ! -x $tc/aarch64-linux-android-4.9/bin/aarch64-linux-android-ld ]]; then
        echo "downloading aarch64-linux-android-4.9"
        mkdir -p "$tc/aarch64-linux-android-4.9"
        curl -sSfL "$GCC_URL" | tar xz -C "$tc/aarch64-linux-android-4.9"
    fi
    "$tc/clang-r383902/bin/clang" --version | grep -qF "$CLANG_BANNER" \
        || die "unexpected clang version"
    "$tc/aarch64-linux-android-4.9/bin/aarch64-linux-android-ld" --version | grep -qF "$LD_BANNER" \
        || die "unexpected binutils version"
    echo "toolchain ready in $tc"
}

cmd_source() {
    need unzip tar git sha256sum
    local dl=$WORK/dl src=$WORK/kernel
    mkdir -p "$dl"
    rm -rf "$src"
    mkdir -p "$src"

    local up at name sum how inner
    while read -r up at name sum how; do
        [[ -z $up || $up == \#* ]] && continue
        if [[ ! -f $dl/$name ]] || ! echo "$sum  $dl/$name" | sha256sum -c --quiet 2>/dev/null; then
            echo "downloading $name"
            "$here/scripts/fetch-samsung.sh" "$up" "$at" "$dl/$name"
        fi
        echo "$sum  $dl/$name" | sha256sum -c --quiet || die "checksum mismatch for $name"

        case $how in
            base)
                unzip -p "$dl/$name" Kernel.tar.gz | tar xz -C "$src"
                ;;
            update)
                inner=$(unzip -Z1 "$dl/$name" | grep -i 'kernel\.tar\.gz$')
                unzip -p "$dl/$name" "$inner" | tar xz --strip-components=1 -C "$src"
                ;;
            *) die "unknown source type $how" ;;
        esac
        echo "applied $name ($how)"
    done < "$here/kernel/sources.txt"

    # git apply outside a repository; the ceiling keeps it from treating
    # work/ as part of this project's repository
    local p
    for p in "$here"/kernel/patches/*.patch; do
        (cd "$src" && GIT_CEILING_DIRECTORIES=$(dirname "$src") git apply -p1 "$p")
        echo "patched: $(basename "$p")"
    done
}

cmd_kernel() {
    need podman
    [[ -f $WORK/kernel/Makefile ]] || die "no kernel source (run ./build.sh source)"
    [[ -x $WORK/toolchains/clang-r383902/bin/clang ]] || die "no toolchain (run ./build.sh toolchain)"

    if ! podman image exists "$BUILD_IMAGE"; then
        podman build --arch amd64 -t "$BUILD_IMAGE" -f - "$here" <<'EOF'
FROM docker.io/library/debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
        make bc bison flex perl python3 cpio kmod libssl-dev libelf-dev \
        libyaml-dev gcc libc6-dev ca-certificates rsync xz-utils lz4 \
    && rm -rf /var/lib/apt/lists/*
EOF
    fi

    mkdir -p "$WORK/out"
    # The paths inside the container are the ones of the tested build;
    # they end up in the kernel image (__FILE__ in warnings).
    podman run --rm \
        -e KBUILD_BUILD_USER -e KBUILD_BUILD_HOST \
        -e KBUILD_BUILD_TIMESTAMP -e KBUILD_BUILD_VERSION \
        -v "$WORK/kernel:/work/kernel:Z" \
        -v "$WORK/out:/work/out-nouh:Z" \
        -v "$WORK/toolchains:/tc:ro,z" \
        -v "$here/kernel/nouh.config:/work/nouh.config:ro,z" \
        -w /work "$BUILD_IMAGE" bash -euo pipefail -c '
            export ARCH=arm64 PLATFORM_VERSION=14 ANDROID_MAJOR_VERSION=u
            # __DATE__ and __TIME__ from KBUILD_BUILD_TIMESTAMP; clang 11
            # ignores SOURCE_DATE_EPOCH for them
            {
                echo "#define __DATE__ \"$(date -u -d "$KBUILD_BUILD_TIMESTAMP" "+%b %e %Y")\""
                echo "#define __TIME__ \"$(date -u -d "$KBUILD_BUILD_TIMESTAMP" "+%H:%M:%S")\""
            } > /work/out-nouh/build-date.h
            # HOSTCFLAGS=-fcommon: the 4.19 dtc defines yylloc twice,
            # which links only with the pre-GCC-10 default.
            make=(make -C /work/kernel O=/work/out-nouh ARCH=arm64
                  CROSS_COMPILE=/tc/aarch64-linux-android-4.9/bin/aarch64-linux-android-
                  CC=/tc/clang-r383902/bin/clang
                  CLANG_TRIPLE=aarch64-linux-gnu-
                  HOSTCFLAGS=-fcommon
                  "KCFLAGS=-Wno-builtin-macro-redefined -include /work/out-nouh/build-date.h"
                  -j"$(nproc)")
            "${make[@]}" exynos5515-freshbl_defconfig
            while read -r opt; do
                [[ -z $opt || $opt == \#* ]] && continue
                /work/kernel/scripts/config --file /work/out-nouh/.config --disable "$opt"
            done < /work/nouh.config
            "${make[@]}" olddefconfig
            "${make[@]}"
        '
    ls -l "$WORK/out/arch/arm64/boot/Image"
    sha256sum "$WORK/out/arch/arm64/boot/Image"
}

# Unpacks one image from the AP tarball to work/fw/<name>.img, converting
# sparse images to raw ones.
unpack_ap_image() {
    local ap=$1 name=$2 out=$WORK/fw/$2.img
    tar xOf "$ap" "$name.img.lz4" | lz4 -dc > "$out.tmp"
    if [[ $(head -c 4 "$out.tmp" | od -An -tx4 | tr -d ' ') == ed26ff3a ]]; then
        simg2img "$out.tmp" "$out"
        rm "$out.tmp"
    else
        mv "$out.tmp" "$out"
    fi
    echo "$(sha256sum "$out" | cut -c1-16)  fw/$name.img"
}

cmd_firmware() {
    local ap=${1:?AP tarball of R870XXU1IYI1}
    need tar lz4 simg2img
    mkdir -p "$WORK/fw"
    local n
    for n in boot dtbo vbmeta vbmeta_system metadata userdata super; do
        unpack_ap_image "$ap" "$n"
    done
}

cmd_trustlets() {
    local img=${1:?JZG3 vendor or super image}
    need debugfs sha256sum
    local tmp out=$WORK/trustlets
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    local vendor=$img
    if [[ $(head -c 4 "$img" | od -An -tx4 | tr -d ' ') == ed26ff3a ]]; then
        need simg2img
        simg2img "$img" "$tmp/raw.img"
        img=$tmp/raw.img
        vendor=$img
    fi
    # a super image has the LP metadata magic 0x616c4467 at 4096
    if [[ $(dd if="$img" bs=1 skip=4096 count=4 2>/dev/null | od -An -tx4 | tr -d ' ') == 616c4467 ]]; then
        need lpunpack
        lpunpack -p vendor "$img" "$tmp"
        vendor=$tmp/vendor.img
    fi

    rm -rf "$out"
    mkdir -p "$out"
    # debugfs warns that it cannot set the owner as a normal user
    debugfs -R "rdump /tee $tmp" "$vendor" >/dev/null 2>&1 || true
    cp -r "$tmp/tee/." "$out/"
    (cd "$out" && sha256sum -c --quiet "$here/overlay/trustlets-R870XXS2JZG3.sha256") \
        || die "trustlets do not match R870XXS2JZG3"
    echo "trustlets in $out"
}

# Patches the IYI1 boot image with the Magisk APK given, on this computer,
# with the APK's own boot_patch.sh: the x86_64 magiskboot, and magiskinit,
# magisk and init-ld for the watch's ABI. The options are those the Magisk
# app chose on the watch; with Magisk 31.1 the result is byte for byte the
# image the app made (STATUS.md). PREINITDEVICE is what
# 'magisk --preinit-device' prints on the watch.
cmd_magisk() {
    local apk=${1:?Magisk APK}
    need unzip
    [[ -f $WORK/fw/boot.img ]] || die "no firmware (run ./build.sh firmware)"
    local abi=${MAGISK_ABI:-armeabi-v7a} out=$WORK/magisk_patched.img tmp f
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    unzip -p "$apk" assets/boot_patch.sh > "$tmp/boot_patch.sh"
    unzip -p "$apk" lib/x86_64/libmagiskboot.so > "$tmp/magiskboot"
    for f in magiskinit magisk init-ld; do
        unzip -p "$apk" "lib/$abi/lib$f.so" > "$tmp/$f"
    done
    for f in boot_patch.sh magiskboot magiskinit magisk init-ld; do
        [[ -s $tmp/$f ]] || die "$f not found in $apk"
    done
    cp "$WORK/fw/boot.img" "$tmp/boot.img"

    # boot_patch.sh without util_functions.sh (SOURCEDMODE): it only needs
    # these three functions from it
    (cd "$tmp" && SOURCEDMODE=1 BOOTMODE=true \
        PREINITDEVICE=${PREINITDEVICE:-mmcblk0p33} \
        KEEPVERITY=false KEEPFORCEENCRYPT=true PATCHVBMETAFLAG=false \
        RECOVERYMODE=false LEGACYSAR=false \
        bash -c 'ui_print() { echo "$1"; }
                 abort() { echo "$1" >&2; exit 1; }
                 grep_prop() { sed -n "s/^$1=//p" "$2"; }
                 . ./boot_patch.sh boot.img' >/dev/null 2>&1) \
        || die "boot_patch.sh failed"
    "$tmp/magiskboot" cpio "$tmp/ramdisk.cpio" test >/dev/null 2>&1 && die "ramdisk not patched"

    # The stock image ends with an AVB footer, and so does the repacked
    # one. The app's image had none; with it, 'magiskboot repack' in
    # 'images' would append the stock vbmeta to boot.img. Remove it.
    local size
    size=$(stat -c %s "$tmp/new-boot.img")
    if [[ $(tail -c 64 "$tmp/new-boot.img" | head -c 4) == AVBf ]]; then
        truncate -s $((size - 64)) "$tmp/new-boot.img"
        truncate -s "$size" "$tmp/new-boot.img"
    fi
    mv "$tmp/new-boot.img" "$out"
    echo "$(sha256sum "$out" | cut -c1-16)  magisk_patched.img"
}

cmd_images() {
    local magisk_boot
    magisk_boot=$(realpath "${1:?IYI1 boot.img patched with Magisk}")
    need_magiskboot
    need python3 gzip
    local dtc=$WORK/out/scripts/dtc/dtc image=$WORK/out/arch/arm64/boot/Image
    local STRIP=$WORK/toolchains/aarch64-linux-android-4.9/bin/aarch64-linux-android-strip
    [[ -x $STRIP ]] || die "no toolchain (run ./build.sh toolchain)"
    [[ -x $dtc && -f $image ]] || die "no kernel build (run ./build.sh kernel)"
    [[ -f $WORK/fw/vbmeta.img ]] || die "no firmware (run ./build.sh firmware)"
    [[ -d $WORK/trustlets ]] || die "no trustlets (run ./build.sh trustlets)"

    local out=$WORK/images tmp
    mkdir -p "$out"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    # vbmeta, vbmeta_system, dtbo: stock IYI1 without the Samsung footer
    python3 -I "$here/scripts/strip-signature.py" vbmeta "$WORK/fw/vbmeta.img" \
        "$out/vbmeta.img" "$SIZE_VBMETA" --disable-verification
    python3 -I "$here/scripts/strip-signature.py" vbmeta "$WORK/fw/vbmeta_system.img" \
        "$out/vbmeta_system.img" "$SIZE_VBMETA"
    python3 -I "$here/scripts/strip-signature.py" dtbo "$WORK/fw/dtbo.img" \
        "$out/dtbo.img" "$SIZE_DTBO"

    # boot: the Magisk-patched IYI1 image with our kernel, a patched DTB
    # and the TEE overlay in the ramdisk
    (cd "$tmp" && "$MAGISKBOOT" unpack -n "$magisk_boot" >/dev/null 2>&1) \
        || die "cannot unpack $magisk_boot"
    gzip -t "$tmp/ramdisk.cpio" 2>/dev/null || die "expected a gzip ramdisk"

    python3 -I "$here/scripts/dt-table.py" extract "$tmp/dtb" "$tmp/base.dtb"
    "$dtc" -q -I dtb -O dts -o "$tmp/base.dts" "$tmp/base.dtb"
    python3 -I "$here/scripts/patch-dts.py" "$tmp/base.dts" "$tmp/patched.dts"
    "$dtc" -q -I dts -O dtb -o "$tmp/patched.dtb" "$tmp/patched.dts"
    python3 -I "$here/scripts/dt-table.py" replace "$tmp/dtb" "$tmp/patched.dtb" "$tmp/dtb.new"
    mv "$tmp/dtb.new" "$tmp/dtb"

    # Magisk's DEFEX hexpatch (the same 3 bytes Magisk changes in the stock
    # kernel), then gzip: bootloader rev2 does not boot a raw Image
    cp "$image" "$tmp/kernel.raw"
    "$MAGISKBOOT" hexpatch "$tmp/kernel.raw" 821B8012 E2FF8F12 >/dev/null \
        || die "DEFEX pattern not found in the kernel"
    gzip -9 -n -c "$tmp/kernel.raw" > "$tmp/kernel"

    local ovl=$tmp/overlay f m ops=()
    mkdir -p "$ovl/overlay.d/sbin"
    install -m 0644 "$here"/overlay/overlay.d/*.rc "$ovl/overlay.d/"
    install -m 0755 "$here"/overlay/overlay.d/sbin/*.sh "$ovl/overlay.d/sbin/"
    # TEE trustlets of R870XXS2JZG3
    while IFS= read -r f; do
        install -m 0644 "$WORK/trustlets/$f" "$ovl/overlay.d/sbin/tee-jzg3-${f//\//_}"
    done < <(cd "$WORK/trustlets" && find . -type f | sed 's|^\./||' | sort)
    # the two modules of /lib/modules on the One UI 6 system partition,
    # built with this kernel; debug info stripped like Samsung's
    for m in drivers/net/wireless/infineon/ifxdhd/ifxdhd.ko drivers/video/backlight/lcd.ko; do
        [[ -f $WORK/out/$m ]] || die "module $m not built"
        "$STRIP" --strip-debug -o "$ovl/overlay.d/sbin/kmod-$(basename "$m")" "$WORK/out/$m"
        chmod 0644 "$ovl/overlay.d/sbin/kmod-$(basename "$m")"
    done

    ops+=("mkdir 0750 overlay.d" "mkdir 0750 overlay.d/sbin")
    while IFS= read -r f; do
        ops+=("add $(stat -c %a "$ovl/$f") $f $ovl/$f")
    done < <(cd "$ovl" && find . -type f | sed 's|^\./||' | sort)
    gzip -dc "$tmp/ramdisk.cpio" > "$tmp/ramdisk.raw"
    (cd "$tmp" && "$MAGISKBOOT" cpio ramdisk.raw "${ops[@]}" >/dev/null)
    gzip -9 -n -c "$tmp/ramdisk.raw" > "$tmp/ramdisk.cpio"

    (cd "$tmp" && "$MAGISKBOOT" repack -n "$magisk_boot" "$out/boot.img" >/dev/null 2>&1) \
        || die "repack failed"
    [[ $(stat -c %s "$out/boot.img") -le $SIZE_BOOT ]] || die "boot.img larger than the partition"
    # pad with zeros to the partition size, so the whole partition is
    # defined and can be checked by hash after writing
    truncate -s "$SIZE_BOOT" "$out/boot.img"

    (cd "$out" && sha256sum boot.img dtbo.img vbmeta.img vbmeta_system.img)
}

case ${1:-} in
    tools|toolchain|source|kernel|firmware|trustlets|magisk|images)
        c=$1; shift; "cmd_$c" "$@" ;;
    *)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
        exit 2 ;;
esac
