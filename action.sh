#!/system/bin/sh
# 管理器里的“操作”按钮：一键 开/关 亮度上托，无需重启
MODDIR=${0%/*}
CONF=/data/adb/brightness_boost.conf
PIDFILE=/data/local/tmp/brightness_boost.pid
LOG=/data/local/tmp/brightness_boost.log

cur=$(grep '^ENABLE=' "$CONF" 2>/dev/null | cut -d= -f2)
[ -n "$cur" ] || cur=1

if [ "$cur" = "1" ]; then
    # 关闭：改写配置并停掉守护
    if [ -f "$CONF" ]; then
        sed 's/^ENABLE=.*/ENABLE=0/' "$CONF" > "${CONF}.tmp" 2>/dev/null && mv "${CONF}.tmp" "$CONF"
    else
        echo "ENABLE=0" > "$CONF"
    fi
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
        rm -f "$PIDFILE"
    fi
    pkill -f "brightnessd.sh" 2>/dev/null
    echo "[亮度上托] 已关闭"
else
    # 开启：改写配置；仅在守护没活着时才拉起，避免双实例
    if [ -f "$CONF" ]; then
        sed 's/^ENABLE=.*/ENABLE=1/' "$CONF" > "${CONF}.tmp" 2>/dev/null && mv "${CONF}.tmp" "$CONF"
    fi
    RUNNING=0
    if [ -f "$PIDFILE" ]; then
        opid=$(cat "$PIDFILE" 2>/dev/null)
        case "$opid" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$opid" 2>/dev/null && grep -q brightnessd "/proc/$opid/cmdline" 2>/dev/null && RUNNING=1 ;;
        esac
    fi
    if [ "$RUNNING" = "1" ]; then
        echo "[亮度上托] 已在运行"
    else
        rm -f "$PIDFILE"
        nohup sh "$MODDIR/brightnessd.sh" >/dev/null 2>&1 &
        echo "[亮度上托] 已开启，把亮度条拉到最大档即生效"
    fi
fi
