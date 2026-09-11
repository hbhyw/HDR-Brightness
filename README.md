# 亮度上托 Brightness Boost

一个 Magisk / KernelSU / APatch 模块，直接控制安卓内核背光节点：自动把亮度上托到更高目标值、WebUI 滑杆实时手动调节、或锁定亮度不被系统抢回。

## 功能

- **自动上托（boost）**：把系统亮度条拉到最大档后，守护进程平滑爬升（80 级步进 + 50ms 间隔）到目标亮度（默认 3685/4095），息屏、调暗、被系统连续抢回时自动让步
- **手动实时（manual）**：在 WebUI 拖动滑杆直写内核背光节点，守护进程完全避让
- **锁定（lock）**：写住选定亮度，DisplayEngine 一抢回立即回写；检测到持续对抢时自动冷却约 5 秒防闪烁，随后继续夺回；息屏暂停、亮屏自动恢复
- **WebUI 控制台**：KernelSU/APatch 管理器模块页网页图标直接打开，实时亮度、模式切换、快捷档、全部参数热保存
- **安装时自动探测节点**：自动识别 `panel0-backlight` / `panel-backlight` / `lcd-backlight` 等背光节点并钉死记录
- **hbm_mode 联动**：若设备存在 `hbm_mode` 节点，亮度达到半量程以上时自动置 1
- 息屏一律不动作，不影响息屏显示与功耗

## 安装

1. 在 KernelSU / Magisk / APatch 管理器中刷入 `brightness_boost_v1.2.1.zip`
2. 重启
3. 打开模块页面，点击模块的网页图标进入 WebUI

不重启也可直接打开 WebUI 使用（守护会在首次操作时自动拉起）。

## 使用说明

WebUI 提供四种状态：

| 模式 | 说明 |
| --- | --- |
| 手动实时 | 拖滑杆立即写入节点，亮度完全由你掌控 |
| 自动上托 | 把亮度条拉到系统最大档，自动平滑爬到目标值 |
| 锁定 | 锁定滑杆选定亮度，系统抢不回 |
| 关闭 | 守护停止，亮度交还系统 |

快捷档：`2047`（系统手动满档）、`3685`（高亮）、`4095`（极限）。

「参数设置」折叠区可在线调整：

- `TRIGGER`：自动上托触发下限
- `TARGET`：上托目标亮度
- `STEP` / `STEP_MS`：爬升步长与间隔
- `POLL_MS`：守护轮询间隔
- `LOCK_TOL`：锁定偏差容忍
- `hbm_mode` 自动联动开关

保存后约 1 秒热生效，无需重启。

## 文件与路径

| 路径 | 作用 |
| --- | --- |
| `/data/adb/brightness_boost.conf` | 配置文件（WebUI 可读写） |
| `/data/adb/brightness_boost.node` | 安装时探测并钉死的背光节点 |
| `/data/local/tmp/brightness_boost.lock` | 锁定模式的目标亮度 |
| `/data/local/tmp/brightness_boost.log` | 守护日志（超过 64KB 自动清空） |
| `/data/local/tmp/brightness_boost.pid` | 守护进程 PID |

管理器模块页的「操作」按钮可一键开/关。

命令行手动调用后端：

```sh
su -c 'sh /data/adb/modules/brightness_boost/cli.sh status'
```

## 关于高亮度 / HDR

- 4095 级背光面板上，2047 通常是系统手动满档（约 500nit），更高区间属于 HBM，正常需要 HDR 内容或阳光模式才会被系统合法下发
- 本模块通过直写 sysfs + 锁定对抗实现高亮度，属于软方案：系统抢得凶时会短暂让步防闪
- HBM 硬件保护（时长窗口、高温拉回）是固件固有约束，任何软件方案都无法绕过
- 持久强制 HDR 亮度需要 Zygisk/LSPosed 层 hook framework，不在本模块范围内

## 兼容性

- 理论支持所有可读 `/sys/class/backlight/*/brightness` 的安卓设备
- 主要在小米13U HyperOS4 a17上开发验证
- 不同机型节点名与 max_brightness 不同，安装时会自动探测

## 免责声明

长时间使用高亮度/HBM 可能增加屏幕烧屏风险与发热，请自行评估后果。本模块不对任何硬件损坏负责。

## 许可证

MIT
