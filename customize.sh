#!/system/bin/sh
# =====================================================================
#  customize.sh —— 安装时执行（被 installer source，不是 exec）
#  这里只做三件事：修权限、打印设备真实情况、检查用户自带的 .ko
# =====================================================================

ui_print " "
ui_print "***********************************************"
ui_print " USB RNDIS 网卡支持 (SIMCom 1E0E:3487)"
ui_print " 适用于 SukiSU / KernelSU / Magisk"
ui_print "***********************************************"
ui_print " 架构     : $ARCH"
ui_print " Android  : API $API"
ui_print " 内核     : $(uname -r)"
ui_print " "

# ---- 权限：脚本 0755，其余 0644 -------------------------------------
set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in post-fs-data.sh service.sh action.sh uninstall.sh bin/net-up.sh bin/udhcpc.script; do
    [ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done

# ---- 内核支持情况 ---------------------------------------------------
if [ -d /sys/bus/usb/drivers/rndis_host ]; then
    ui_print "- 内核里已经有 rndis_host（内建或已加载）"
    ui_print "  → 本模块只需要负责把 usb0 配起来，开箱即用。"
else
    ui_print "- 当前内核里没有 rndis_host"
    FOUND_KO=""
    for d in /vendor/lib/modules /lib/modules /system/lib/modules \
             /vendor_dlkm/lib/modules /system_dlkm/lib/modules; do
        if ls "$d"/rndis_host.ko >/dev/null 2>&1; then
            FOUND_KO="$d/rndis_host.ko"
            break
        fi
    done
    if [ -n "$FOUND_KO" ]; then
        ui_print "  但在 $FOUND_KO 找到了 .ko，开机会自动 modprobe。"
    else
        ui_print "  也没找到 rndis_host.ko —— 需要自己编一个（README 第 9 节），"
        ui_print "  编好后放进模块目录 ko/rndis_host.ko 再刷一次。"
    fi
fi

# ---- 用户自带 .ko 的 vermagic 检查 ---------------------------------
USER_KO=""
for k in "$MODPATH"/ko/*.ko; do
    [ -f "$k" ] && { USER_KO="$k"; break; }
done

if [ -n "$USER_KO" ]; then
    ui_print " "
    ui_print "- 自带驱动：$(basename "$USER_KO")"
    VM=$(strings "$USER_KO" 2>/dev/null | grep -m1 '^vermagic=' | cut -d= -f2-)
    KR=$(uname -r)
    ui_print "    ko vermagic : ${VM:-<读不到>}"
    ui_print "    运行内核    : $KR"
    # 实测：这套 GKI 内核并不比对 vermagic（改版本号/改 gki 段都能加载），
    # 真正决定能否加载的是 ABI（结构体布局）和 CFI 类型哈希。
    ui_print "  （本内核不校验 vermagic，版本号不一致不代表不能加载；"
    ui_print "    加载失败请看 dmesg 里 CFI / Unknown symbol 的报错）"
fi

ui_print " "
ui_print "- 安装完成。重启后插上设备，用下面命令看状态："
ui_print "    su -c 'sh /data/adb/modules/simcom_rndis_otg/action.sh'"
ui_print " "

# ---- 清理安装残留 ---------------------------------------------------
rm -rf "$MODPATH/customize.sh" 2>/dev/null
