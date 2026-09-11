#!/system/bin/sh
# 开机自启：late_start service 阶段由 Magisk / KernelSU 调起
MODDIR=${0%/*}

# 等开机完成，再给系统 8 秒稳定期，避免和开机亮度初始化打架
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done
sleep 8

# 清理可能残留的 pid（重启后必然失效，由守护自行重判）
rm -f /data/local/tmp/brightness_boost.pid

# ENABLE=0 时守护会自行退出
nohup sh "$MODDIR/brightnessd.sh" >/dev/null 2>&1 &
