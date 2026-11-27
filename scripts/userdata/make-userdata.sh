#!/usr/bin/env bash
# Makes an empty f2fs image the size of the whole userdata partition, with the
# same features as the factory userdata.img (encrypt, verity, extra_attr,
# project_quota, quota_ino, casefold, compression), to flash instead of the
# 2 GiB factory image. On the first boot vold encrypts it in place, the same
# as the factory image.
#
#   ./make-userdata.sh <output image> [size in bytes]
#
# Default size: 8942256128, the userdata partition of the SM-R870 and SM-R860
# (both have the same PIT). Needs mkfs.f2fs and fsck.f2fs (f2fs-tools).
set -euo pipefail
OUT=$1 SIZE=${2:-8942256128}
WANT="encrypt verity extra_attr project_quota quota_ino casefold compression"

rm -f -- "$OUT"
truncate -s "$SIZE" "$OUT"
mkfs.f2fs -f -g android -O compression -O extra_attr -O casefold -C utf8 "$OUT" >/dev/null
log=$(fsck.f2fs --dry-run "$OUT" 2>&1) || { echo "fsck.f2fs failed on $OUT:"; echo "$log"; exit 1; }
got=$(sed -n 's/^Info: superblock features = [0-9a-f]* : *//p' <<<"$log")
[ "$got" = "$WANT" ] || { echo "unexpected features: '$got'"; exit 1; }
echo "$OUT: f2fs, $SIZE bytes, features: $got"
