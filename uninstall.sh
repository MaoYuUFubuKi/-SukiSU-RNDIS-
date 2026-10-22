#!/system/bin/sh
# 卸载时清理：停守护进程、删临时状态。
# 驱动本身是内核里的，不需要（也无法）卸载。

PIDFILE=/data/local/tmp/simcom_rndis.pid
if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
fi
rm -f /data/local/tmp/simcom_rndis.state \
      /data/local/tmp/simcom_rndis.gw \
      /data/local/tmp/simcom_rndis.dns \
      /data/local/tmp/simcom_rndis.udhcpc.pid
exit 0
