#!/system/bin/sh
# =====================================================================
#  post-fs-data.sh  —— 开机最早阶段：确保 rndis_host 驱动在场
#
#  为什么放在 post-fs-data 而不是 service.sh：
#    驱动要在别的模块/服务开始操作 USB 之前就绪；这一步很快（只 insmod），
#    不会超过 KernelSU 给 post-fs-data 的 10 秒预算。
#    如果这一阶段 insmod 被 SELinux 挡住，可以改用 preinit
#    （见本目录 preinit.conf.sample，或 README 第 8 节）。
# =====================================================================

MODDIR=${0%/*}
. "$MODDIR/config.conf" 2>/dev/null

LOG=${LOG:-/data/local/tmp/simcom_rndis.log}
mkdir -p /data/local/tmp 2>/dev/null

log() { echo "[$(date '+%m-%d %H:%M:%S')] [post-fs-data] $*" >>"$LOG"; }

# 已经内建或已经加载过（/sys/bus/usb/drivers/<drv> 只有驱动注册成功才会出现）
if [ -d /sys/bus/usb/drivers/rndis_host ]; then
    log "rndis_host 已在（内建或已加载），无需处理"
    exit 0
fi

log "未检测到 rndis_host，开始尝试加载；内核 $(uname -r)"

# ---------------------------------------------------------------------
# 方式一：modprobe（会按 modules.dep 自动带依赖 usbnet / cdc_ether / mii）
# ---------------------------------------------------------------------
try_modprobe() {
    command -v modprobe >/dev/null 2>&1 || return 1
    modprobe rndis_host 2>>"$LOG" && return 0
    /system/bin/modprobe -d /vendor/lib/modules rndis_host 2>>"$LOG" && return 0
    /system/bin/modprobe -d /lib/modules        rndis_host 2>>"$LOG" && return 0
    return 1
}

# ---------------------------------------------------------------------
# 方式二：insmod 指定候选目录（包括模块自带的 ko/ 目录）
# ---------------------------------------------------------------------
try_insmod() {
    _m=$1
    for _d in "$MODDIR/ko" /vendor/lib/modules /lib/modules /system/lib/modules \
              /vendor_dlkm/lib/modules /system_dlkm/lib/modules; do
        [ -f "$_d/$_m.ko" ] || continue
        if insmod "$_d/$_m.ko" 2>>"$LOG"; then
            log "insmod $_d/$_m.ko 成功"
            return 0
        fi
        log "insmod $_d/$_m.ko 失败（继续下一个）"
    done
    return 1
}

if try_modprobe; then
    log "modprobe rndis_host 成功"
    exit 0
fi

# 先手动补齐依赖，再加载本体
for _dep in usbnet cdc_ether mii; do
    try_insmod "$_dep" >/dev/null 2>&1
done

if try_insmod rndis_host; then
    exit 0
fi

if [ -d /sys/bus/usb/drivers/rndis_host ]; then
    log "驱动已注册（可能是依赖模块带进来的）"
else
    log "失败：内核里没有 rndis_host，也没有可加载的 .ko。"
    log "      请按 README 第 9 节编译 rndis_host.ko 后放进模块 ko/ 目录，"
    log "      或换一个带 USB_RNDIS_HOST 的内核。"
fi

exit 0
