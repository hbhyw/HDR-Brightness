#!/system/bin/sh
# Magisk / KernelSU 模块安装脚本 v1.2.1

ui_print "-=================================="
ui_print "- 亮度上托 Brightness Boost v1.2.1"
ui_print "- 自动上托 / 手动实时 / 锁定三模式"
ui_print "- WebUI 实时滑杆，系统抢回可锁死"
ui_print "-=================================="

# 安装时探测背光节点并钉死（开机后守护直接使用，不再猜）
NODE=""
for c in /sys/class/backlight/panel0-backlight/brightness \
         /sys/class/backlight/panel-backlight/brightness \
         /sys/class/leds/lcd-backlight/brightness \
         /sys/class/leds/led:backlight/brightness; do
    [ -f "$c" ] || continue
    v=$(cat "$c" 2>/dev/null)
    case "$v" in
        ''|*[!0-9]*) continue ;;
    esac
    NODE="$c"
    break
done

if [ -n "$NODE" ]; then
    echo "$NODE" > /data/adb/brightness_boost.node
    ui_print "- 已锁定背光节点:"
    ui_print "  $NODE"
    MAX=$(cat "${NODE%/*}/max_brightness" 2>/dev/null)
    [ -n "$MAX" ] && ui_print "  最大亮度 = $MAX"
    [ -f "${NODE%/*}/hbm_mode" ] && ui_print "  检测到 hbm_mode 节点(将自动联动)"
else
    ui_print "- 安装时未探测到背光节点"
    ui_print "  守护会在开机后自动重新探测"
fi

# 不要对 webroot 设置权限，管理器会自动处理其 SELinux 上下文
set_perm "$MODPATH/service.sh"     0 0 0755
set_perm "$MODPATH/brightnessd.sh" 0 0 0755
set_perm "$MODPATH/action.sh"      0 0 0755
set_perm "$MODPATH/cli.sh"         0 0 0755

ui_print "- 安装完成，重启后在模块页点网页图标打开"
