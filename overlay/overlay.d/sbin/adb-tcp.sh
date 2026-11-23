#!/system/bin/sh
# Restarts adbd listening on TCP 5555 with key authentication off.
# $1 is the Magisk tmpfs (for resetprop).
$1/magisk resetprop ro.adb.secure 0
setprop service.adb.tcp.port 5555
stop adbd
start adbd
echo "adb-tcp: adbd on tcp 5555" > /dev/kmsg
