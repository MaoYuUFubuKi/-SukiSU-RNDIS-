#!/system/bin/sh
# =====================================================================
#  bin/net-up.sh  —— 守护进程：等 RNDIS 网卡出现，然后配 IP / 路由 / DNS
#
#  设计要点：
#   * 一直在后台轮询，支持“开机后再插”、“拔了再插”。
#   * 优先 DHCP（模组自带 DHCP 服务），失败退回固定地址 + 探测网关。
#   * 默认路由写进 main 表：Android 在“没有其它默认网络”时，
#     未打 fwmark 的流量会查 main 表（README 第 10 节详细解释）。
# =====================================================================

MODDIR=$(cd "${0%/*}/.." 2>/dev/null && pwd)
[ -n "$MODDIR" ] || MODDIR=${0%/*}/..
. "$MODDIR/config.conf" 2>/dev/null

LOG=${LOG:-/data/local/tmp/simcom_rndis.log}
POLL=${POLL:-5}
STATE=/data/local/tmp/simcom_rndis.state
GWFILE=/data/local/tmp/simcom_rndis.gw
DNSFILE=/data/local/tmp/simcom_rndis.dns

mkdir -p /data/local/tmp 2>/dev/null

log() { echo "[$(date '+%m-%d %H:%M:%S')] [net-up] $*" >>"$LOG"; }

# ---------------------------------------------------------------- busybox
find_busybox() {
    for _b in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox \
              /data/adb/magisk/busybox /data/adb/ksud/bin/busybox; do
        [ -x "$_b" ] && { echo "$_b"; return 0; }
    done
    command -v busybox 2>/dev/null && return 0
    return 1
}
BUSYBOX=$(find_busybox)
[ -n "$BUSYBOX" ] || log "警告：没找到 busybox，DHCP 可能不可用"

resetprop_bin() {
    for _r in /data/adb/ksu/bin/resetprop /data/adb/magisk/resetprop /system/bin/resetprop; do
        [ -x "$_r" ] && { echo "$_r"; return 0; }
    done
    return 1
}
RESETPROP=$(resetprop_bin)

# ---------------------------------------------------------------- 找网卡
pick_iface() {
    # 1) 手写死网卡名
    if [ "$IFNAME" != "auto" ] && [ -n "$IFNAME" ]; then
        [ -e "/sys/class/net/$IFNAME" ] && { echo "$IFNAME"; return 0; }
        return 1
    fi

    # 2) 按驱动识别：driver 指向 rndis_host 的网卡
    for _n in /sys/class/net/*; do
        _i=${_n##*/}
        [ "$_i" = "lo" ] && continue
        _drv=$(readlink -f "$_n/device/driver" 2>/dev/null)
        case "$_drv" in
            */rndis_host) echo "$_i"; return 0 ;;
        esac
    done

    # 3) 退化：usbnet 默认命名
    for _i in usb0 usb1 usb2; do
        [ -e "/sys/class/net/$_i" ] && { echo "$_i"; return 0; }
    done
    return 1
}

has_ipv4() {
    ip -4 addr show dev "$1" 2>/dev/null | grep -q 'inet '
}

# ---------------------------------------------------------------- DHCP
try_dhcp() {
    _i=$1
    [ -n "$BUSYBOX" ] || return 1
    "$BUSYBOX" udhcpc -i "$_i" -s "$MODDIR/bin/udhcpc.script" \
        -p /data/local/tmp/simcom_rndis.udhcpc.pid \
        -f -n -q -t 4 -T 2 >/dev/null 2>&1
    has_ipv4 "$_i"
}

# ---------------------------------------------------------------- 固定地址
try_static() {
    _i=$1
    for _gw in "$STATIC_GW" 192.168.0.1 192.168.42.129 192.168.1.1 192.168.225.1; do
        [ -n "$_gw" ] || continue
        ip addr flush dev "$_i" 2>/dev/null
        ip addr add "$STATIC_IP/$STATIC_PREFIX" dev "$_i" 2>/dev/null || continue
        ip link set "$_i" up 2>/dev/null
        if ping -c 1 -W 1 -I "$_i" "$_gw" >/dev/null 2>&1; then
            ip route replace default via "$_gw" dev "$_i" 2>/dev/null
            echo "$_gw" > "$GWFILE"
            log "固定地址模式：$STATIC_IP/$STATIC_PREFIX，网关 $_gw"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------- DNS
apply_dns() {
    _d1=$1; _d2=$2
    [ -n "$_d1" ] || _d1=$DNS1
    [ -n "$_d2" ] || _d2=$DNS2

    if [ -n "$RESETPROP" ]; then
        "$RESETPROP" net.dns1 "$_d1" 2>/dev/null
        "$RESETPROP" net.dns2 "$_d2" 2>/dev/null
    else
        setprop net.dns1 "$_d1" 2>/dev/null
        setprop net.dns2 "$_d2" 2>/dev/null
    fi
    log "DNS -> $_d1 $_d2"
}

# ---------------------------------------------------------------- 可选：netd
ndc_setup() {
    _i=$1; _gw=$2
    [ -n "$_gw" ] || return 0
    command -v ndc >/dev/null 2>&1 || return 0
    ndc network create "$NDC_NETID" 2>/dev/null
    ndc network interface add "$NDC_NETID" "$_i" 2>/dev/null
    ndc network route add "$NDC_NETID" "$_i" 0.0.0.0/0 "$_gw" 2>/dev/null
    ndc resolver setnetdns "$NDC_NETID" "" "$DNS1" "$DNS2" 2>/dev/null
    if ndc network default set "$NDC_NETID" 2>/dev/null; then
        log "ndc：netd 默认网络 = $NDC_NETID"
    else
        log "ndc：设置默认网络失败（忽略，走 main 表）"
    fi
}

# ---------------------------------------------------------------- 主流程
# 自己写 pid，service.sh 用这个文件来停旧实例（setsid 的 $! 不可靠）
echo $$ > /data/local/tmp/simcom_rndis.pid

log "守护进程启动（pid $$），内核 $(uname -r)"

LAST_IFACE=""
EXCLUSIVE_DONE=0

while true; do
    IFACE=$(pick_iface)

    if [ -z "$IFACE" ]; then
        if [ -n "$LAST_IFACE" ]; then
            log "网卡 $LAST_IFACE 已消失（拔掉了？），等待重新插入"
            LAST_IFACE=""
        fi
        sleep "$POLL"
        continue
    fi

    # 网卡在，但没地址 / 刚插上 → 配置
    if [ "$LAST_IFACE" != "$IFACE" ] || ! has_ipv4 "$IFACE"; then
        log "发现网卡 $IFACE，开始配置"

        ip link set "$IFACE" up 2>/dev/null
        if [ -w "/proc/sys/net/ipv6/conf/$IFACE/disable_ipv6" ]; then
            echo 1 > "/proc/sys/net/ipv6/conf/$IFACE/disable_ipv6" 2>/dev/null
        fi

        OK=0
        if [ "$DHCP" = "1" ]; then
            if try_dhcp "$IFACE"; then
                log "DHCP 成功：$(ip -4 addr show dev "$IFACE" | grep 'inet ' | tr -s ' ')"
                OK=1
            else
                log "DHCP 失败，改用固定地址"
            fi
        fi
        [ "$OK" = "1" ] || { try_static "$IFACE" && OK=1; }

        if [ "$OK" = "1" ]; then
            # 确保默认路由在
            GW=$(cat "$GWFILE" 2>/dev/null)
            if [ -z "$GW" ]; then
                GW=$(ip route show default 2>/dev/null | grep "dev $IFACE" | head -n1 | awk '{print $3}')
            fi
            [ -n "$GW" ] && ip route replace default via "$GW" dev "$IFACE" 2>/dev/null

            D=$(cat "$DNSFILE" 2>/dev/null)
            D1=$(echo "$D" | awk '{print $1}')
            D2=$(echo "$D" | awk '{print $2}')
            apply_dns "$D1" "$D2"

            [ "$USE_NDC" = "1" ] && ndc_setup "$IFACE" "$GW"

            if [ "$EXCLUSIVE" = "1" ] && [ "$EXCLUSIVE_DONE" = "0" ]; then
                log "独占模式：关闭 Wi-Fi / 移动数据"
                svc wifi disable 2>/dev/null
                svc data disable 2>/dev/null
                EXCLUSIVE_DONE=1
            fi

            {
                echo "iface=$IFACE"
                echo "gw=${GW:-none}"
                echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
            } > "$STATE"
            LAST_IFACE="$IFACE"
            log "配置完成：$IFACE 网关 ${GW:-none}"
        else
            log "$IFACE 配置失败（没有拿到地址），${POLL}s 后重试"
            LAST_IFACE=""
        fi
    fi

    sleep "$POLL"
done
