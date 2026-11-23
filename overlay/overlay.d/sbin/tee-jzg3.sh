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
chcon u:object_r:tee_file:s0 $dst 2>/dev/kmsg

bind() {
    cp "$src/$1" "$dst/$1" 2>/dev/kmsg
    chmod 0644 "$dst/$1"
    # same label as /vendor/tee in the vendor file_contexts
    chcon u:object_r:tee_file:s0 "$dst/$1" 2>/dev/kmsg
    if mount -o bind "$dst/$1" "/vendor/tee/$2" 2>/dev/kmsg; then
        log "ok $2 $(ls -Z "/vendor/tee/$2" | cut -d' ' -f1)"
    else
        log "FAILED $2"
    fi
}
bind tee-jzg3-00000000-0000-0000-0000-000000534b4d 00000000-0000-0000-0000-000000534b4d
bind tee-jzg3-00000000-0000-0000-0000-0053545354ab 00000000-0000-0000-0000-0053545354ab
bind tee-jzg3-00000000-0000-0000-0000-474154454b45 00000000-0000-0000-0000-474154454b45
bind tee-jzg3-00000000-0000-0000-0000-4b45594d5354 00000000-0000-0000-0000-4b45594d5354
bind tee-jzg3-00000000-0000-0000-0000-505256544545 00000000-0000-0000-0000-505256544545
bind tee-jzg3-00000000-0000-0000-0000-53454d655345 00000000-0000-0000-0000-53454d655345
bind tee-jzg3-driver_00000000-0000-0000-0000-494363447256 driver/00000000-0000-0000-0000-494363447256
bind tee-jzg3-ffffffff-0000-0000-0000-000000000030 ffffffff-0000-0000-0000-000000000030
log "done"
