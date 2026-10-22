#!/system/bin/sh
# =====================================================================
#  service.sh  —— late_start 阶段
#
#  默认 AUTO_NET=0：只靠 post-fs-data.sh 加载 rndis_host 驱动，
#  网络交给 Android 的以太网服务（EthernetTracker 认 usb\d / eth\d）。
#  只有 AUTO_NET=1 时才拉起本模块自己的配网守护进程。
# =====================================================================

MODDIR=${0%/*}
. "$MODDIR/config.conf" 2>/dev/null
LOG=${LOG:-/data/local/tmp/simcom_rndis.log}
PIDFILE=/data/local/tmp/simcom_rndis.pid

mkdir -p /data/local/tmp 2>/dev/null

if [ "${AUTO_NET:-0}" != "1" ]; then
    echo "[$(date '+%m-%d %H:%M:%S')] [service] AUTO_NET=0：网络交给系统以太网服务，跳过自定义配网" >>"$LOG"
    exit 0
fi

# 先收拾上一轮的实例，避免重复配置
if [ -f "$PIDFILE" ]; then
    OLD=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$OLD" ]; then
        kill "$OLD" 2>/dev/null
        sleep 1
        kill -9 "$OLD" 2>/dev/null
    fi
    rm -f "$PIDFILE"
fi

# setsid：脱离当前会话，service.sh 退出后守护进程继续跑
if command -v setsid >/dev/null 2>&1; then
    setsid sh "$MODDIR/bin/net-up.sh" >>"$LOG" 2>&1 &
else
    sh "$MODDIR/bin/net-up.sh" >>"$LOG" 2>&1 &
fi

echo "[$(date '+%m-%d %H:%M:%S')] [service] 已拉起配网守护进程" >>"$LOG"
