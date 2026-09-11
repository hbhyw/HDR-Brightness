#!/system/bin/sh
# 亮度上托守护进程 v1.2.1
# 模式:
#   boost  自动上托：亮度进入 [TRIGGER,TARGET) 且非下降时平滑爬升到 TARGET
#   manual 手动实时：WebUI 直写节点，守护完全避让（仅 hbm_mode 随值切换）
#   lock   锁定：写住 LOCKVAL，系统一旦抢回立即回写；持续对抢时短暂冷却防闪
# 息屏一律不动作

MODDIR=${0%/*}
CONF=/data/adb/brightness_boost.conf
NODEPIN=/data/adb/brightness_boost.node
LOCKFILE=/data/local/tmp/brightness_boost.lock
LOG=/data/local/tmp/brightness_boost.log
PIDFILE=/data/local/tmp/brightness_boost.pid

# ---------- 单实例（kill -0 + cmdline 双重确认，防 PID 复用误判） ----------
daemon_alive() {
    [ -f "$PIDFILE" ] || return 1
    _pid=$(cat "$PIDFILE" 2>/dev/null)
    case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$_pid" 2>/dev/null || return 1
    grep -q brightnessd "/proc/$_pid/cmdline" 2>/dev/null
}
if daemon_alive; then
    # 已有实例在跑：退出前撤掉 EXIT trap，避免误删对方的 pidfile
    trap - EXIT
    exit 0
fi
echo $$ > "$PIDFILE"
trap 'exit 0' TERM INT
trap 'rm -f "$PIDFILE"' EXIT

# ---------- 默认配置 ----------
ENABLE=1
MODE=boost
TRIGGER=2000
TARGET=3685
STEP=80
STEP_MS=50
POLL_MS=200
HBM_AUTO=1           # 存在 hbm_mode 节点时，>=MAX/2 自动置1，低于置0
LOCK_TOL=40          # 锁定偏差容忍(约1%，避开节点量化抖动)
LOCK_FIGHT=8         # 连续多少个轮询周期被抢回 -> 冷却(8*200ms≈1.6s)
LOCK_COOL=25         # 锁定对抢冷却周期(25*200ms≈5s)
COOLDOWN_TICKS=8
PENALTY_TICKS=50
ABORT_FAILS=2

# ---------- 工具 ----------
is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

LOGN=0
log() {
    read up _ < /proc/uptime 2>/dev/null
    echo "[${up%%.*}s] $1" >> "$LOG"
    LOGN=$((LOGN + 1))
    if [ $LOGN -ge 100 ]; then
        LOGN=0
        SZ=$(wc -c < "$LOG" 2>/dev/null)
        case "$SZ" in *[!0-9]*|'') ;; *) [ "$SZ" -gt 65536 ] && : > "$LOG" ;; esac
    fi
}

# ---------- 节点：优先安装时探测并钉死的记录，否则运行时探测 ----------
NODE=""
if [ -s "$NODEPIN" ]; then
    p=$(cat "$NODEPIN" 2>/dev/null)
    [ -n "$p" ] && [ -f "$p" ] && NODE="$p"
fi
if [ -z "$NODE" ]; then
    for c in /sys/class/backlight/panel0-backlight/brightness \
             /sys/class/backlight/panel-backlight/brightness \
             /sys/class/leds/lcd-backlight/brightness \
             /sys/class/leds/led:backlight/brightness; do
        [ -f "$c" ] || continue
        v0=$(cat "$c" 2>/dev/null) || continue
        is_num "$v0" || continue
        if echo "$v0" > "$c" 2>/dev/null; then NODE="$c"; break; fi
    done
    [ -n "$NODE" ] && echo "$NODE" > "$NODEPIN" 2>/dev/null
fi

if [ -z "$NODE" ]; then
    log "FATAL: 找不到可写的背光节点，守护退出"
    exit 1
fi
DIR=${NODE%/*}
MAX=$(cat "$DIR/max_brightness" 2>/dev/null)
is_num "$MAX" || MAX=4095
BLP="$DIR/bl_power"
[ -f "$BLP" ] || BLP=""
HBMNODE="$DIR/hbm_mode"
[ -f "$HBMNODE" ] || HBMNODE=""
LASTHBM="x"
[ -n "$HBMNODE" ] && LASTHBM=$(cat "$HBMNODE" 2>/dev/null)
is_num "$LASTHBM" || LASTHBM="x"

# ---------- 配置文件 ----------
if [ ! -f "$CONF" ]; then
    {
        echo "# 亮度上托配置 (WebUI 在线修改，约 1 秒热生效)"
        echo "ENABLE=1"
        echo "MODE=boost        # boost=自动上托 manual=手动实时 lock=锁定"
        echo "TRIGGER=$TRIGGER"
        echo "TARGET=$TARGET"
        echo "STEP=$STEP"
        echo "STEP_MS=$STEP_MS"
        echo "POLL_MS=$POLL_MS"
        echo "HBM_AUTO=1        # 存在 hbm_mode 节点时高亮度自动开启"
        echo "LOCK_TOL=$LOCK_TOL"
    } > "$CONF" 2>/dev/null
fi
[ -f "$CONF" ] && . "$CONF" 2>/dev/null
[ "$ENABLE" = "1" ] || exit 0

sanitize() {
    is_num "$TARGET" || TARGET=3685
    [ "$TARGET" -gt "$MAX" ] && TARGET="$MAX"
    is_num "$TRIGGER" || TRIGGER=2000
    is_num "$STEP" || STEP=80
    [ "$STEP" -lt 1 ] && STEP=80
    is_num "$STEP_MS" || STEP_MS=50
    is_num "$POLL_MS" || POLL_MS=200
    [ "$POLL_MS" -lt 50 ] && POLL_MS=200
    is_num "$LOCK_TOL" || LOCK_TOL=40
    [ "$HBM_AUTO" = "0" ] || HBM_AUTO=1
    POLL_US=$((POLL_MS * 1000))
    STEP_US=$((STEP_MS * 1000))
}
sanitize

screen_on() {
    if [ -n "$BLP" ]; then
        bp=$(cat "$BLP" 2>/dev/null)
        [ "$bp" = "0" ] || return 1
    fi
    return 0
}

# 按亮度值维护 hbm_mode（仅在节点存在且 HBM_AUTO=1 时）
hbm_ensure() {
    [ "$HBM_AUTO" = "1" ] && [ -n "$HBMNODE" ] || return 0
    want=0
    [ "$1" -ge $((MAX / 2)) ] && want=1
    [ "$want" = "$LASTHBM" ] && return 0
    echo "$want" > "$HBMNODE" 2>/dev/null && LASTHBM=$want
}

# ---------- 平滑上托 ----------
do_ramp() {
    v="$1"
    fails=0
    hbm_ensure "$TARGET"
    while [ "$v" -lt "$TARGET" ]; do
        screen_on || { log "息屏，中止上托 @ $v"; return 2; }
        n=$((v + STEP))
        [ "$n" -gt "$TARGET" ] && n="$TARGET"
        echo "$n" > "$NODE" 2>/dev/null
        usleep "$STEP_US"
        a=$(cat "$NODE" 2>/dev/null)
        is_num "$a" || { log "节点读数异常，中止"; return 1; }
        if [ "$a" -lt $((n - STEP / 2)) ]; then
            fails=$((fails + 1))
            if [ "$fails" -ge "$ABORT_FAILS" ]; then
                log "系统连续抢回($a)，放弃上托，进入惩罚冷却"
                return 1
            fi
        else
            fails=0
        fi
        v="$a"
    done
    log "上托完成 -> $v"
    return 0
}

log "守护启动 node=$NODE max=$MAX hbm=$HBMNODE mode=$MODE trigger=$TRIGGER target=$TARGET"

# 每轮热重载
reload_conf() {
    ENABLE=1; MODE=boost
    [ -f "$CONF" ] && . "$CONF" 2>/dev/null
    if [ "$ENABLE" != "1" ]; then
        log "配置 ENABLE=0，守护退出"
        exit 0
    fi
    sanitize
}

# ---------- 主循环 ----------
PREV=0
COOL=0
FIGHT=0
LASTMODE=""
while true; do
    usleep "$POLL_US"
    [ "$COOL" -gt 0 ] && COOL=$((COOL - 1))
    reload_conf
    [ "$MODE" != "$LASTMODE" ] && { log "模式切换: $LASTMODE -> $MODE"; FIGHT=0; COOL=0; LASTMODE=$MODE; }

    CUR=$(cat "$NODE" 2>/dev/null)
    is_num "$CUR" || continue

    # 息屏：只同步基准
    if ! screen_on; then
        PREV="$CUR"
        continue
    fi

    # ===== 锁定模式 =====
    if [ "$MODE" = "lock" ]; then
        LV=$(cat "$LOCKFILE" 2>/dev/null)
        if ! is_num "$LV"; then LV=$TARGET; echo "$LV" > "$LOCKFILE" 2>/dev/null; fi
        [ "$LV" -gt "$MAX" ] && LV=$MAX
        hbm_ensure "$LV"

        d=$((CUR - LV)); [ "$d" -lt 0 ] && d=$((-d))
        if [ "$d" -le "$LOCK_TOL" ]; then
            FIGHT=0
            PREV="$CUR"
            continue
        fi

        # 对抢冷却中：不动作（防闪），冷却结束后再尝试夺回
        if [ "$COOL" -gt 0 ]; then
            PREV="$CUR"
            continue
        fi

        echo "$LV" > "$NODE" 2>/dev/null
        usleep 30000
        a=$(cat "$NODE" 2>/dev/null)
        is_num "$a" && {
            d2=$((a - LV)); [ "$d2" -lt 0 ] && d2=$((-d2))
            if [ "$d2" -gt "$LOCK_TOL" ]; then
                FIGHT=$((FIGHT + 1))
                if [ "$FIGHT" -ge "$LOCK_FIGHT" ]; then
                    log "锁定值 $LV 被系统持续抢回(当前 $a)，冷却 ${LOCK_COOL} 个周期防闪"
                    COOL=$LOCK_COOL
                    FIGHT=0
                fi
            else
                [ $FIGHT -gt 0 ] && log "锁定夺回成功 -> $a"
                FIGHT=0
            fi
        }
        PREV="$CUR"
        continue
    fi

    # 手动实时模式：WebUI 直写，守护避让
    if [ "$MODE" = "manual" ]; then
        FIGHT=0
        PREV="$CUR"
        continue
    fi

    # ===== boost 自动上托 =====
    if [ "$CUR" -lt "$PREV" ]; then
        PREV="$CUR"
        continue
    fi
    if [ "$CUR" -lt "$TRIGGER" ] || [ "$CUR" -ge "$TARGET" ]; then
        PREV="$CUR"
        continue
    fi
    if [ "$COOL" -gt 0 ]; then
        PREV="$CUR"
        continue
    fi

    log "触发上托 cur=$CUR prev=$PREV"
    do_ramp "$CUR"
    rc=$?
    if [ "$rc" -eq 1 ]; then
        COOL=$PENALTY_TICKS
    else
        COOL=$COOLDOWN_TICKS
    fi
    PREV=$(cat "$NODE" 2>/dev/null)
    is_num "$PREV" || PREV=0
done
