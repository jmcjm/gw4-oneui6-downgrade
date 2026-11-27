#!/usr/bin/env bash
# Copies the start of the userdata partition from the Wi-Fi recovery in
# 128 MiB chunks and checks every chunk against a SHA-256 computed on the
# watch. Run only in the Wi-Fi recovery, with /data not mounted.
#
#   ./pull-chunks.sh <adb serial> <output dir> <MiB>
#
# <MiB>: the size of the existing filesystem (block_count * 4096), rounded up
# to 128 MiB. Writes <output dir>/userdata-enc.NN and SHA256SUMS.
set -uo pipefail
S=$1 OUT=$2 MIB=$3
DEV=/dev/block/by-name/userdata
[[ $MIB =~ ^[0-9]+$ ]] && (( MIB > 0 && MIB % 128 == 0 )) \
  || { echo "size must be a positive multiple of 128 MiB"; exit 2; }
mkdir -p "$OUT" && chmod 700 "$OUT"
umask 077

a() { timeout "${T:-300}" adb -s "$S" "$@" </dev/null; }
reconnect() { adb disconnect "$S" >/dev/null 2>&1 </dev/null; timeout 10 adb connect "$S" >/dev/null 2>&1 </dev/null; }

[ "$(a shell 'grep -c " /data " /proc/mounts' | tr -d '\r\n')" = 0 ] \
  || { echo "/data mounted or no adb: not in the Wi-Fi recovery? STOP"; exit 1; }
: > "$OUT/SHA256SUMS"
for i in $(seq 0 $((MIB / 128 - 1))); do
  f=$OUT/userdata-enc.$(printf %02d "$i")
  ok=
  for try in 1 2 3; do
    a exec-out "dd if=$DEV bs=1048576 skip=$((i*128)) count=128 2>/dev/null" > "$f"
    want=$(a shell "dd if=$DEV bs=1048576 skip=$((i*128)) count=128 2>/dev/null | sha256sum" | cut -d' ' -f1)
    got=$(sha256sum "$f" | cut -d' ' -f1)
    if [ "$want" = "$got" ] && [ "$(stat -c %s "$f")" = 134217728 ]; then ok=1; break; fi
    echo "chunk $i: mismatch, try $try"
    reconnect; sleep 5
  done
  [ -n "$ok" ] || { echo "chunk $i FAILED"; exit 1; }
  echo "$got  $(basename "$f")" >> "$OUT/SHA256SUMS"
  echo "chunk $i OK"
done
echo PULL_DONE
