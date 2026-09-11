#!/system/bin/sh
# WebUI 后端 v1.2.1（由 KernelSU/APatch 管理器以 root 执行）
#   cli.sh status                 状态 JSON
#   cli.sh set <0..max>           写亮度(锁定模式下同时更新锁定值，按值切 hbm_mode)
#   cli.sh mode <boost|manual|lock>
#   cli.sh enable <0|1>
#   cli.sh save <KEY> <VALUE>
#   cli.sh restart

MODDIR=${0%/*}
CONF=/data/adb/brightness_boost.conf
NODEPIN=/data/adb/brightness_boost.node
LOCKFILE=/data/local/tmp/brightness_boost.lock
PIDFILE=/data/local/tmp/brightness_boost.pid

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# 守护是否真的在跑（cmdline 校验，防 PID 复用误判）
daemon_alive() {
    [ -f "$PIDFILE" ] || return 1
    _pid=$(cat "$PIDFILE" 2>/dev/null)
    case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$_pid" 2>/dev/null || return 1
    grep -q brightnessd "/proc/$_pid/cmdline" 2>/dev/null
}

probe_node() {
    if [ -s "$NODEPIN" ]; then
        p=$(cat "$NODEPIN" 2>/dev/null)
        [ -n "$p" ] && [ -f "$p" ] && { echo "$p"; return 0; }
    fi
    for c in /sys/class/backlight/panel0-backlight/brightness \
             /sys/class/backlight/panel-backlight/brightness \
             /sys/class/leds/lcd-backlight/brightness \
             /sys/class/leds/led:backlight/brightness; do
        [ -f "$c" ] || continue
        v=$(cat "$c" 2>/dev/null)
        is_num "$v" || continue
        echo "$c" > "$NODEPIN" 2>/dev/null
        echo "$c"
        return 0
    done
    return 1
}

setkv() {
    k=$1; v=$2
    if grep -q "^$k=" "$CONF" 2>/dev/null; then
        sed "s/^$k=.*/$k=$v/" "$CONF" > "${CONF}.tmp" 2>/dev/null && mv "${CONF}.tmp" "$CONF"
    else
        echo "$k=$v" >> "$CONF"
    fi
}

start_daemon() {
    # 已在运行直接返回，严禁删 pidfile 重启，否则会出现双守护实例
    daemon_alive && return 0
    pgrep -f "brightnessd.sh" >/dev/null 2>&1 && return 0
    rm -f "$PIDFILE"
    nohup sh "$MODDIR/brightnessd.sh" >/dev/null 2>&1 &
}

stop_daemon() {
    if daemon_alive; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
    fi
    rm -f "$PIDFILE"
    pkill -f "brightnessd.sh" 2>/dev/null
}

cmd=$1
case "$cmd" in

status)
    NODE=$(probe_node)
    if [ -z "$NODE" ]; then
        echo '{"ok":0,"err":"no_node"}'
        exit 0
    fi
    DIR=${NODE%/*}
    CUR=$(cat "$NODE" 2>/dev/null); is_num "$CUR" || CUR=0
    MAX=$(cat "$DIR/max_brightness" 2>/dev/null); is_num "$MAX" || MAX=4095
    BP=$(cat "$DIR/bl_power" 2>/dev/null); is_num "$BP" || BP=0
    [ "$CUR" -gt "$MAX" ] && CUR=$MAX
    HBMEX=0; HBMVAL=-1
    if [ -f "$DIR/hbm_mode" ]; then HBMEX=1; HBMVAL=$(cat "$DIR/hbm_mode" 2>/dev/null); is_num "$HBMVAL" || HBMVAL=-1; fi

    ENABLE=1; MODE=boost; TRIGGER=2000; TARGET=3685; STEP=80; STEP_MS=50; POLL_MS=200
    HBM_AUTO=1; LOCK_TOL=40
    # 必须先判 -f：POSIX sh(mksh) 下 source 不存在的文件会直接终止整个脚本
    [ -f "$CONF" ] && . "$CONF" 2>/dev/null

    LOCKVAL=$(cat "$LOCKFILE" 2>/dev/null); is_num "$LOCKVAL" || LOCKVAL="$TARGET"

    ALIVE=0
    daemon_alive && ALIVE=1
    [ "$BP" = "0" ] && SCREEN=1 || SCREEN=0

    printf '{"ok":1,"cur":%s,"max":%s,"screen":%s,"alive":%s,"enable":%s,"mode":"%s","trigger":%s,"target":%s,"step":%s,"step_ms":%s,"poll_ms":%s,"lockval":%s,"lock_tol":%s,"hbm_exist":%s,"hbm":%s,"hbm_auto":%s,"node":"%s"}\n' \
        "$CUR" "$MAX" "$SCREEN" "$ALIVE" "$ENABLE" "$MODE" \
        "$TRIGGER" "$TARGET" "$STEP" "$STEP_MS" "$POLL_MS" \
        "$LOCKVAL" "$LOCK_TOL" "$HBMEX" "$HBMVAL" "$HBM_AUTO" "$NODE"
    ;;

set)
    NODE=$(probe_node)
    [ -z "$NODE" ] && { echo '{"ok":0,"err":"no_node"}'; exit 0; }
    DIR=${NODE%/*}
    MAX=$(cat "$DIR/max_brightness" 2>/dev/null); is_num "$MAX" || MAX=4095
    v=$2
    is_num "$v" || { echo '{"ok":0,"err":"bad_value"}'; exit 0; }
    [ "$v" -lt 0 ] && v=0
    [ "$v" -gt "$MAX" ] && v=$MAX

    # 锁定模式：同步更新锁定值，守护会负责看住
    MODE=boost; ENABLE=1
    [ -f "$CONF" ] && . "$CONF" 2>/dev/null
    if [ "$MODE" = "lock" ]; then
        echo "$v" > "$LOCKFILE" 2>/dev/null
    fi

    # hbm_mode 守卫：存在且开启自动时按半量程切换
    if [ "$HBM_AUTO" = "1" ] && [ -f "$DIR/hbm_mode" ]; then
        want=0; [ "$v" -ge $((MAX / 2)) ] && want=1
        cur_hbm=$(cat "$DIR/hbm_mode" 2>/dev/null)
        [ "$cur_hbm" != "$want" ] && echo "$want" > "$DIR/hbm_mode" 2>/dev/null
    fi

    echo "$v" > "$NODE" 2>/dev/null
    a=$(cat "$NODE" 2>/dev/null); is_num "$a" || a=$v
    echo "{\"ok\":1,\"cur\":$a}"
    ;;

mode)
    case "$2" in
        boost|manual|lock)
            setkv ENABLE 1
            setkv MODE "$2"
            # 进入锁定：把锁定值钉为【当前】亮度
            if [ "$2" = "lock" ]; then
                NODE=$(probe_node)
                if [ -n "$NODE" ]; then
                    cv=$(cat "$NODE" 2>/dev/null)
                    is_num "$cv" && echo "$cv" > "$LOCKFILE"
                fi
            fi
            # 幂等确保守护在跑（已在运行则直接返回，不会起第二实例）
            start_daemon
            echo "{\"ok\":1,\"mode\":\"$2\"}" ;;
        *) echo '{"ok":0,"err":"bad_mode"}' ;;
    esac
    ;;

enable)
    case "$2" in
        1) setkv ENABLE 1; start_daemon; echo '{"ok":1,"enable":1}' ;;
        0) setkv ENABLE 0; stop_daemon; echo '{"ok":1,"enable":0}' ;;
        *) echo '{"ok":0,"err":"bad_enable"}' ;;
    esac
    ;;

save)
    k=$2; v=$3
    case "$k" in
        MODE)
            case "$v" in boost|manual|lock) ;; *) echo '{"ok":0,"err":"bad_value"}'; exit 0 ;; esac ;;
        HBM_AUTO)
            case "$v" in 0|1) ;; *) echo '{"ok":0,"err":"bad_value"}'; exit 0 ;; esac ;;
        TRIGGER|TARGET|STEP|STEP_MS|POLL_MS|LOCK_TOL)
            is_num "$v" || { echo '{"ok":0,"err":"bad_value"}'; exit 0; } ;;
        *) echo '{"ok":0,"err":"bad_key"}'; exit 0 ;;
    esac
    setkv "$k" "$v"
    echo "{\"ok\":1,\"$k\":\"$v\"}"
    ;;

restart)
    setkv ENABLE 1
    stop_daemon
    sleep 1
    start_daemon
    echo '{"ok":1}'
    ;;

*)
    echo '{"ok":0,"err":"unknown_cmd"}'
    ;;
esac
