#!/system/bin/sh
# Bind-mounts the kernel modules (copied by magiskinit from overlay.d/sbin
# to $1 as kmod-<name>.ko) over /lib/modules/<name>.ko. The copies live in
# /dev/kmod: 'magisk --post-fs-data' relabels the Magisk tmpfs.
src=$1
dst=/dev/kmod
log() { echo "kmod: $*" > /dev/kmsg; }

mkdir -p $dst
chmod 0755 $dst
for f in $src/kmod-*.ko; do
    [ -f "$f" ] || continue
    name=${f##*/kmod-}
    cp "$f" "$dst/$name" 2>/dev/kmsg
    chmod 0644 "$dst/$name"
    # same label as the files in /lib/modules on the system partition
    chcon u:object_r:rootfs:s0 "$dst/$name" 2>/dev/kmsg
    if mount -o bind "$dst/$name" "/lib/modules/$name" 2>/dev/kmsg; then
        log "ok $name"
    else
        log "FAILED $name"
    fi
done
