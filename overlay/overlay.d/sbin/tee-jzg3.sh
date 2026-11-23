#!/system/bin/sh
# Bind-mounts the JZG3 trustlets (copied by magiskinit from overlay.d/sbin
# to $1) over /vendor/tee. Results go to the kernel log.
#
# The files are copied to /dev/tee-jzg3 first: 'magisk --post-fs-data'
# relabels everything under the Magisk tmpfs, which would take away the
# tee_file label that the gatekeeper HAL needs to read its trustlet.
src=$1
dst=/dev/tee-jzg3
log() { echo "tee-jzg3: $*" > /dev/kmsg; }

mkdir -p $dst
chmod 0755 $dst
# One cp, chmod and chcon for all files: the script runs synchronously
# on 'fs', so every process it starts delays the boot.
cp "$src"/tee-jzg3-* $dst/ 2>/dev/kmsg
chmod 0644 $dst/tee-jzg3-*
# same label as /vendor/tee in the vendor file_contexts
chcon u:object_r:tee_file:s0 $dst $dst/tee-jzg3-* 2>/dev/kmsg

bind() {
    mount -o bind "$dst/$1" "/vendor/tee/$2" 2>/dev/kmsg || log "FAILED $2"
}
bind tee-jzg3-00000000-0000-0000-0000-000000534b4d 00000000-0000-0000-0000-000000534b4d
bind tee-jzg3-00000000-0000-0000-0000-0053545354ab 00000000-0000-0000-0000-0053545354ab
bind tee-jzg3-00000000-0000-0000-0000-474154454b45 00000000-0000-0000-0000-474154454b45
bind tee-jzg3-00000000-0000-0000-0000-4b45594d5354 00000000-0000-0000-0000-4b45594d5354
bind tee-jzg3-00000000-0000-0000-0000-505256544545 00000000-0000-0000-0000-505256544545
bind tee-jzg3-00000000-0000-0000-0000-53454d655345 00000000-0000-0000-0000-53454d655345
bind tee-jzg3-driver_00000000-0000-0000-0000-494363447256 driver/00000000-0000-0000-0000-494363447256
bind tee-jzg3-ffffffff-0000-0000-0000-000000000030 ffffffff-0000-0000-0000-000000000030
# the labels as seen through the mounts, in one ls
ls -Z /vendor/tee/0* /vendor/tee/f* /vendor/tee/driver/0* 2>&1 | while read -r l; do log "$l"; done
log "done"
