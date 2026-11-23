#!/usr/bin/env bash
# Writes an image to a watch partition from the Wi-Fi recovery, in chunks.
#
#   ./flash-chunks.sh <adb serial> <image> <partition>
#
# 'adb exec-in' truncates long streams in this recovery, so each 128 MiB
# chunk is sent with 'adb push -z zstd' to /tmp (tmpfs), checked, written
# with dd at its offset, and read back from the partition. At the end the
# hash of the first <image size> bytes of the partition is compared with
# the image hash.
set -euo pipefail

SERIAL=${1:?adb serial}
IMG=${2:?image}
PART=${3:?partition}
CHUNK_MB=128
BS=$((4 * 1024 * 1024))
PER_CHUNK=$((CHUNK_MB * 1024 * 1024 / BS))

ADB=(adb -s "$SERIAL")
DEV=/dev/block/by-name/$PART
SIZE=$(stat -c %s "$IMG")
PSIZE=$("${ADB[@]}" shell blockdev --getsize64 "$DEV" | tr -d '\r')

if [ "$SIZE" -gt "$PSIZE" ]; then
    echo "image ($SIZE B) larger than $PART ($PSIZE B)" >&2
    exit 1
fi
if [ $((SIZE % BS)) -ne 0 ]; then
    echo "image size $SIZE is not a multiple of 4 MiB" >&2
    exit 1
fi

TOTAL_BLOCKS=$((SIZE / BS))
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "$(date +%T) $IMG -> $PART ($SIZE B, $(( (TOTAL_BLOCKS + PER_CHUNK - 1) / PER_CHUNK )) chunks)"

for ((first = 0; first < TOTAL_BLOCKS; first += PER_CHUNK)); do
    count=$PER_CHUNK
    [ $((first + count)) -gt "$TOTAL_BLOCKS" ] && count=$((TOTAL_BLOCKS - first))

    dd if="$IMG" of="$TMP/chunk" bs="$BS" skip="$first" count="$count" status=none
    want=$(sha256sum "$TMP/chunk" | cut -d' ' -f1)

    "${ADB[@]}" push -z zstd "$TMP/chunk" /tmp/chunk >/dev/null
    got=$("${ADB[@]}" shell sha256sum /tmp/chunk | cut -d' ' -f1)
    [ "$got" = "$want" ] || { echo "push mismatch at block $first" >&2; exit 1; }

    "${ADB[@]}" shell "dd if=/tmp/chunk of=$DEV bs=$BS seek=$first conv=notrunc,fsync 2>/dev/null; rm /tmp/chunk"
    onp=$("${ADB[@]}" shell "dd if=$DEV bs=$BS skip=$first count=$count 2>/dev/null | sha256sum" | cut -d' ' -f1)
    [ "$onp" = "$want" ] || { echo "partition mismatch at block $first" >&2; exit 1; }

    echo "$(date +%T) $PART block $first +$count OK ($(( (first + count) * 100 / TOTAL_BLOCKS ))%)"
done

want=$(sha256sum "$IMG" | cut -d' ' -f1)
onp=$("${ADB[@]}" shell "dd if=$DEV bs=$BS count=$TOTAL_BLOCKS 2>/dev/null | sha256sum" | cut -d' ' -f1)
if [ "$onp" = "$want" ]; then
    echo "$(date +%T) $PART DONE, sha256 ${want:0:16}"
else
    echo "$(date +%T) $PART FINAL MISMATCH: $onp vs $want" >&2
    exit 1
fi
