#!/bin/sh
set -eu
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mkdir -p /tmp
mount -t tmpfs tmpfs /tmp
mkdir -p /dev/shm /root /etc /tmp/runtime
mount -t tmpfs tmpfs /dev/shm
chmod 1777 /tmp /dev/shm
chmod 700 /tmp/runtime
printf 'root:x:0:0:Limiar Probe:/root:/bin/sh\n' > /etc/passwd
printf 'root:x:0:\n' > /etc/group
export HOME=/root
export XDG_RUNTIME_DIR=/tmp/runtime

case " $(cat /proc/cmdline) " in
    *" limiar_probe_delay=2 "*) sleep 2 ;;
esac

echo LIMIAR_DMI_BEGIN
for key in sys_vendor product_name product_version product_serial product_uuid \
    product_sku product_family bios_vendor bios_version bios_date bios_release \
    board_vendor board_name board_version board_serial board_asset_tag \
    chassis_vendor chassis_type chassis_version chassis_serial chassis_asset_tag
do
    path="/sys/class/dmi/id/$key"
    if [ -r "$path" ]; then
        printf 'LIMIAR_DMI %s=%s\n' "$key" "$(cat "$path")"
    fi
done
echo LIMIAR_DMI_END

if [ -c /dev/dxg ]; then
    echo LIMIAR_GPU dxg_device=present
else
    echo LIMIAR_GPU dxg_device=absent
fi

for argument in $(cat /proc/cmdline); do
    case "$argument" in
        limiar_gpu_probe=*)
            target=${argument#limiar_gpu_probe=}
            vendor=${target%:*}
            device=${target#*:}
            export LD_LIBRARY_PATH=/usr/lib/wsl/lib
            if ! /limiar/gpu-probe "$vendor" "$device"; then
                echo LIMIAR_GPU_RENDER_FAILED
            fi
            ;;
    esac
done

printf 'LIMIAR_OS kernel=%s\n' "$(uname -r)"
printf 'LIMIAR_OS online_cpus=%s\n' "$(cat /sys/devices/system/cpu/online)"
printf 'limiar-filesystem-check\n' > /tmp/limiar-check
test "$(cat /tmp/limiar-check)" = "limiar-filesystem-check"
test "$((123 * 456))" -eq 56088
echo LIMIAR_USERSPACE_OK
sync
echo LIMIAR_PROBE_READY
case " $(cat /proc/cmdline) " in
    *" limiar_probe_ack=1 "*)
        IFS= read -r -t 60 acknowledgement < /dev/ttyS0
        test "$acknowledgement" = "limiar-poweroff"
        ;;
esac
poweroff -f
sleep 5
echo LIMIAR_SHUTDOWN_FAILED
exit 1
