#!/system/bin/sh
# =====================================================================
#  action.sh —— 在 SukiSU/KernelSU 管理器里点“执行”时运行，输出状态
#  也可以手动跑： su -c 'sh /data/adb/modules/simcom_rndis_otg/action.sh'
# =====================================================================

MODDIR=${0%/*}
. "$MODDIR/config.conf" 2>/dev/null
LOG=${LOG:-/data/local/tmp/simcom_rndis.log}

echo "===== 内核 ====="
echo "版本   : $(uname -r)"
if [ -d /sys/bus/usb/drivers/rndis_host ]; then
    echo "rndis_host: 已注册 ✓"
else
    echo "rndis_host: 未注册 ✗（看 post-fs-data 日志）"
fi
ls /sys/module 2>/dev/null | grep -E '^(usbnet|rndis_host|cdc_ether)$' | sed 's/^/已加载模块: /'

echo
echo "===== USB 设备 ====="
for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] || continue
    v=$(cat "$d/idVendor" 2>/dev/null)
    p=$(cat "$d/idProduct" 2>/dev/null)
    if [ "$v" = "1e0e" ]; then
        echo "$(basename "$d"): $v:$p  $(cat "$d/product" 2>/dev/null)"
    fi
done

echo
echo "===== 网卡 ====="
ip -o link show 2>/dev/null | grep -E 'usb|rndis|eth' | sed 's/^/  /'
echo
ip -4 addr show 2>/dev/null | grep -E 'usb|inet ' | sed 's/^/  /'

echo
echo "===== 路由 ====="
ip route show default 2>/dev/null | sed 's/^/  /'
[ -f /data/local/tmp/simcom_rndis.state ] && cat /data/local/tmp/simcom_rndis.state | sed 's/^/  /'

echo
echo "===== DNS ====="
echo "  net.dns1 = $(getprop net.dns1)"
echo "  net.dns2 = $(getprop net.dns2)"

echo
echo "===== 最近日志 ====="
tail -n 25 "$LOG" 2>/dev/null | sed 's/^/  /' || echo "  (还没有日志)"
