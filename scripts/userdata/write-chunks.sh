#!/usr/bin/env bash
# Writes 128 MiB chunks (userdata-enc.NN with SHA256SUMS, as made by split)
# to the userdata partition: every chunk whose current content on the watch
# differs. Run only in the Wi-Fi recovery, with /data not mounted.
#
#   ./write-chunks.sh <adb serial> <chunk dir>
#
# Survives Wi-Fi drops: every push is retried with a timeout and its copy in
# /tmp is hash-checked on the watch; dd and the read-back hash run on the
# watch detached from the adb session, so a dropped connection cannot stop a
# write half way. Chunks that already read back with the right hash are
# skipped, so the script can simply be run again. Also restores the backup
# made by pull-chunks.sh.
set -uo pipefail
S=$1 C=$(cd "$2" && pwd)
DEV=/dev/block/by-name/userdata

# adb must never read the script's stdin: adb shell forwards it to the watch
a() { timeout "${T:-60}" adb -s "$S" "$@" </dev/null; }
reconnect() { adb disconnect "$S" >/dev/null 2>&1 </dev/null; timeout 10 adb connect "$S" >/dev/null 2>&1 </dev/null; }
dev_hash() {
  local h
  for _ in $(seq 1 10); do
    h=$(T=180 a shell "dd if=$DEV bs=1048576 skip=$(($1*128)) count=128 2>/dev/null | sha256sum" | cut -d' ' -f1)
    [ ${#h} -eq 64 ] && { echo "$h"; return 0; }
    reconnect; sleep 5
  done
  return 1
}

(cd "$C" && sha256sum -c --quiet SHA256SUMS) || { echo "local chunks broken, STOP"; exit 1; }
[ "$(a shell 'grep -c " /data " /proc/mounts' | tr -d '\r\n')" = 0 ] \
  || { echo "/data mounted or no adb: not in the Wi-Fi recovery? STOP"; exit 1; }

mapfile -t entries < <(sort -k2 "$C/SHA256SUMS")
total=0
for e in "${entries[@]}"; do
  new=${e%% *} f=${e##* }
  i=$((10#${f##*.}))
  cur=$(dev_hash "$i") || { echo "chunk $i: cannot read the partition, STOP"; exit 1; }
  if [ "$cur" = "$new" ]; then echo "chunk $i already matches"; total=$((total + 1)); continue; fi
  ok=
  for _ in 1 2 3 4 5; do
    T=120 a push "$C/$f" /tmp/chunk >/dev/null 2>&1 || { reconnect; sleep 5; continue; }
    h=$(a shell 'sha256sum /tmp/chunk' | cut -d' ' -f1)
    [ "$h" = "$new" ] && { ok=1; break; }
    reconnect; sleep 5
  done
  [ -n "$ok" ] || { echo "chunk $i: push failed, STOP"; exit 1; }
  a shell "rm -f /tmp/dd.done; nohup sh -c 'dd if=/tmp/chunk of=$DEV bs=1048576 seek=$((i*128)) conv=notrunc,fsync 2>/tmp/dd.err && sync && echo 3 > /proc/sys/vm/drop_caches && dd if=$DEV bs=1048576 skip=$((i*128)) count=128 2>/dev/null | sha256sum | cut -d\" \" -f1 > /tmp/dd.hash; mv /tmp/dd.hash /tmp/dd.done' >/dev/null 2>&1 &"
  got=
  for _ in $(seq 1 120); do
    sleep 3
    got=$(a shell 'cat /tmp/dd.done 2>/dev/null; true' | tr -d '\r\n') || { reconnect; continue; }
    [ -n "$got" ] && break
  done
  [ "$got" = "$new" ] || { echo "chunk $i: read-back hash '$got' differs, STOP"; exit 1; }
  a shell 'rm -f /tmp/chunk /tmp/dd.done /tmp/dd.err'
  echo "chunk $i written and verified"
  total=$((total + 1))
done
[ "$total" -eq "${#entries[@]}" ] || { echo "only $total of ${#entries[@]} chunks handled, STOP"; exit 1; }
a shell sync
echo "WRITE_DONE ($total chunks)"
