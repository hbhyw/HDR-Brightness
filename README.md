# hdr 高亮 · HDR Brightness

> **一个 APK，点一下，安卓的 SDR 亮度上限从 500nit 放开到 1300nit。**
> 免 root、免模块、免 LSPosed，只要给一个「显示在其他应用上层」权限。

作者：汉堡

实测机型：小米 13 Ultra（ishtar / 2304FPN6DC）· HyperOS `OS4.0.0.35.XPBCNXM` · Android 17 · 内核 `5.15.216-ChirunoNeko-A17-260911-Dev`

| 版本 | 文件 | 说明 |
| --- | --- | --- |
| **v1.1.2** | [`hdrwin/HDR-Brightness.apk`](hdrwin/HDR-Brightness.apk) | 20 883 字节。**装这个。** 深色模式 + 修好安装失败 + 修好「给了权限也开不起来」 |
| v1.1.1 | [Release v1.1.1](https://github.com/hbhyw/HDR-Brightness/releases/tag/v1.1.1) | 能装，但没有下面第 2 条修复 |
| v1.1.0 | [Release v1.1.0](https://github.com/hbhyw/HDR-Brightness/releases/tag/v1.1.0) | ❌ 装不上（-124），别用 |
| v1.0.0 | [Release v1.0.0](https://github.com/hbhyw/HDR-Brightness/releases/tag/v1.0.0) | ❌ 同一个打包缺陷，也别用 |

```
v1.1.2  SHA-256  BE40D00878590B04E2B52AE9D4A83D08D3A3C5E3F94BC1C16943903CB415B8C4
签名证书  CN=Android Debug, O=Android, C=US
```

> **v1.0.0 / v1.1.0 的包把 `resources.arsc` 压成了 DEFLATE，装上会报 -124**
> （`Targeting R+ (version 30 and above) requires the resources.arsc of installed APKs to be
> stored uncompressed and aligned on a 4-byte boundary`）。
> 原因和修法见[第六节](#六自己编译)。那两个 Release 留着当记录，别装。

**`HdrWindowService.java` 的 HDR 触发逻辑从 v1.0.0 起就没改过**，v1.1.x 改的都是界面和打包。
下面「实测数据」那张表是用同一份源码在本地构建、装上真机跑出来的；仓库里 v1.0.0 / v1.1.0
那两份 Release 是后来重新构建的产物，才带上了上面这个打包缺陷。`minSdkVersion 34`（Android 14+）。

---

## 一句话原理

在屏幕角落放一张 **8×8 像素、肉眼看不见的 UltraHDR 图片**，
让 SurfaceFlinger 认为「屏幕上有 HDR 图层」，
框架于是把亮度上限从 SDR 的 `0.499938`（≈500nit / 背光 2047）放开到 `1.0`（1300nit / 背光 4095）。

```
UltraHDR JPEG（8×8：主图纯黑 + 一张 gain map）
        │   ImageDecoder（必须用默认分配器；ALLOCATOR_HARDWARE 会把 gain map 丢掉）
        ▼
   HARDWARE Bitmap ──getHardwareBuffer()──► HardwareBuffer（自带 HDR 元数据）
        │
        │   Transaction.setBuffer(sc, buffer)                  ← 直接绑，不经过任何绘制
        │   Transaction.setExtendedRangeBrightness(sc, 4.99, 4.99)
        ▼
   SurfaceView 的 SurfaceControl（40dp 悬浮窗，窗口 alpha = 0.01）
        │
        ▼
   SurfaceFlinger：numHdrLayers(1), size(8x8)
        │
        ▼
   HighBrightnessModeController.mIsHdrLayerPresent = true
        │
        ▼
   calculateHighBrightnessMode() → HBM{hdr} → getCurrentBrightnessMax(): 0.499938 → 1.0
        │
        ▼
   背光 2047 ──► 3839（低电量保护）/ 4095（满档）
```

---

## 一、为什么需要它：SDR 被框架卡在 500nit

小米 13 Ultra 的 SDR 亮度上限不是固件决定的，是 `DisplayPowerController` 决定的：

```
HighBrightnessModeController:
    mHbmData = HBM{minLux: 6001.0, transition: 0.499938, minimumHdrPercentOfScreen: 0.0}
    mNits    = [2.0, 500.0, 1300.0]     // 500nit 是 SDR 上限；1300nit 只有 HDR 通路才给
    mCurrentBrightnessMax = 0.499938     // = 2047 / 4095
```

- **环境光这条路走不通**：`minLux = 6001.0`，而实测室内环境光只有 3~45 lux，永远够不到 HBM 的触发门槛。
- **唯一能上 1300nit 的开关是 `mIsHdrLayerPresent == true`** —— `calculateHighBrightnessMode()` 里只有这个分支会把上限写成 `1.0`。
- **`minimumHdrPercentOfScreen = 0.0`** —— 图层占屏比阈值是 0，**一个像素也算 HDR 图层**。这就是「几像素图片」能行的原因。
- 这不是「骗过固件」：背光节点一直可写，是**框架**在往下压。让框架自己放行，才不会有一秒一次的回写和频闪。

---

## 二、触发条件：四步，缺一不可

调试过程中逐步试出来的组合。少任何一步，`numHdrLayers` 都是 0、`mIsHdrLayerPresent` 都是 false。

### 1. 一张真的 UltraHDR JPEG，解成 HARDWARE 位图

```java
// 主图：不透明纯黑（AMOLED 不发光 → 看不见）；gain map：均匀灰 0xC0
Bitmap base = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888);
new Canvas(base).drawColor(0xFF000000);
Bitmap gain = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888);
new Canvas(gain).drawColor(Color.rgb(0xC0, 0xC0, 0xC0));

Gainmap gm = new Gainmap(gain);
gm.setRatioMin(1f, 1f, 1f);
gm.setRatioMax(4f, 4f, 4f);
gm.setDisplayRatioForFullHdr(4f);
gm.setMinDisplayRatioForHdrTransition(1f);
gm.setGainmapDirection(Gainmap.GAINMAP_DIRECTION_SDR_TO_HDR);
base.setGainmap(gm);
base.compress(Bitmap.CompressFormat.JPEG, 95, out);   // ← 框架自动写 MPF + hdrgm 元数据
```

解码拿 `HardwareBuffer`：

```java
Bitmap src = ImageDecoder.decodeBitmap(ImageDecoder.createSource(jpeg));  // 默认分配器！
Bitmap hw  = src.getConfig() == Bitmap.Config.HARDWARE
           ? src : src.copy(Bitmap.Config.HARDWARE, false);
HardwareBuffer buf = hw.getHardwareBuffer();
```

> **坑**：`ImageDecoder` 传 `ALLOCATOR_HARDWARE` 会得到 `hasGainmap=false` 的位图 —— gain map 直接没了。
> 必须用默认分配器解码，再自己 `copy` 成 HARDWARE。

### 2. 用公开 API 声明 HDR 余量

```java
surfaceView.setDesiredHdrHeadroom(4.99f);   // SurfaceView 的公开 API，API 34+
```

这是普通 App（Google 相册、酷安）走的那条路。**光有 gain map 不够** —— 我一开始用 root 直接
`SurfaceControl.Builder` 造图层，喂同样的 JPEG，`numHdrLayers` 一直是 0，就是因为那样拿不到
`SurfaceView`，也就没机会调这个 API。

### 3. 把 HardwareBuffer **直接绑到 SurfaceControl 上**（最关键的一步）

```java
SurfaceControl sc = surfaceView.getSurfaceControl();
SurfaceControl.Transaction tx = new SurfaceControl.Transaction();
tx.setBuffer(sc, buf);                                   // ← 直接提交
tx.setExtendedRangeBrightness(sc, 4.99f, 4.99f);         // 公开 API
tx.apply();
```

**为什么不能画上去**：Canvas / `HardwareRenderer` / `SurfaceHolder.lockCanvas()` 任何绘制路径
都会在合成 buffer 时把 gain map 和 HDR dataspace 丢掉 —— 实测画出来的 buffer 永远是
`dataspace=0x08810000 (V0_SRGB)`、`hdr metadata types=0`，SurfaceFlinger 自然不认。
唯一有效的做法是**把解码出来的那个 buffer 原样绑定**。

`SurfaceView.getSurfaceControl()` 是公开 API，比反射 `mBlastSurfaceControl` 可靠（那条路字段是 `null`）。

### 4. 强制这一层按 HDR 处理

```java
// Surface.setForceHdrEnabled 是隐藏 API，只能反射
Method m = Surface.class.getDeclaredMethod("setForceHdrEnabled", boolean.class);
m.setAccessible(true);
m.invoke(surface, Boolean.TRUE);
```

### 另外两个必须注意的细节

- **窗口 alpha 不能是 0**：`lp.alpha = 0` 时 SurfaceFlinger 把图层判为「不可见」，直接排除在 HDR 统计外，
  `numHdrLayers` 又变回 0。代码里用 `0.01f` —— 1/100 的透明度肉眼看不见，但图层仍算可见。
- **主图不能全透明**：同理，`alpha=0` 的位图不算数。用的是**不透明纯黑** `0xFF000000`，
  在 AMOLED 上黑像素不发光，效果和全透明一样。

---

## 三、实测数据

`hdrwin/HDR-Brightness.apk`，模块/LSPosed 全部停用，**纯 APK 独立运行**：

| 项 | 关闭 | 开启 |
| --- | --- | --- |
| `mIsHdrLayerPresent` | `false` | **`true`** |
| `mHbmMode` | `off` | **`hdr(1.0)`** |
| `hdrSdrRatio` | `1.0` | **`2.4000003`** |
| SurfaceFlinger HDR 图层数 | 0 | **1（8×8）** |
| 色域 `Current color mode` | `ColorMode::SRGB (7)` | **`ColorMode::SRGB (7)`** ✅ 不偏色 |
| 背光 `/sys/class/backlight/panel0-backlight/brightness` | `2047` | **`3839`** |

- 3839 / 4095 是**低电量保护**下的值：测试时电量 12~16%，日志里有 `hdr low_battery`，
  HDR 峰值被压到约 1200nit。插上充电器可到满档 4095。
- 开 10 次 × 3 秒采样，全程稳定 3839，**零抖动**（没有任何进程在抢写背光节点）。
- 关掉后立刻回到 2047，可反复开关。
- 从桌面点图标能正常启动（`mCurrentFocus=com.hamburger.hdrwin/.MainActivity`）。

### 关于偏色：锅在 `persist.sys.sf.color_mode`

HDR 图层存在时，SurfaceFlinger 按这个属性的值决定要不要切到宽色域：

| `persist.sys.sf.color_mode` | 无 HDR 图层 | 有 HDR 图层 |
| --- | --- | --- |
| **7**（本机出厂值） | `ColorMode::SRGB (7)` | **`ColorMode::SRGB (7)`** ✅ |
| 0 | `ColorMode::SRGB (7)` | **`ColorMode::DISPLAY_P3 (9)`** ❌ 整屏偏色 |

**出厂就是 7，本来就该不偏色**。早前我做实验时把它改成了 `0`，才把「HDR 图层 → 切 P3」这个
切换放了出来，一度以为是 HDR 图层的锅 —— 这是我的错误，已更正。本 App **不碰这个属性**，
保持出厂值即可。

---

## 四、用法

1. 安装 `hdrwin/HDR-Brightness.apk`
2. 打开 App → **「1. 授予悬浮窗权限」**（`SYSTEM_ALERT_WINDOW`，必须的）
3. **「2. 开启」** → 状态显示「已开启」，然后就可以把界面关掉了（服务会常驻一条低优先级通知）
4. **「3. 关闭」** → 图层撤回，亮度交还系统

### 深色模式（v1.1.0）

界面下方有三个选项，默认**跟随系统**：

| 选项 | 做法 |
| --- | --- |
| 跟随系统 | `@style/AppTheme`，`values/` 是浅色、`values-night/` 是深色，系统自己挑 |
| 深色 | `@style/AppTheme.Dark` → `Theme.DeviceDefault.NoActionBar` |
| 浅色 | `@style/AppTheme.Light` → `Theme.DeviceDefault.Light.NoActionBar` |

实现上是 **换主题**（`setTheme()` + `recreate()`），不是一个个 View 去刷颜色 ——
所以按钮、单选框、文字、窗口背景、状态栏图标会一起变，不用维护两套配色。
选择存在 `SharedPreferences`（`hdrwin` / `theme`：0 跟随系统、1 深色、2 浅色）。

顺手做了两件事：

- 主题用的是 `NoActionBar` 变体。界面里本来就自己画了标题，系统那条标题栏是重复的。
- 补上了 `WindowInsets` 让位。`targetSdk 35+` 系统强制全面屏，之前标题会顶到状态栏底下。

也可以命令行：

```sh
adb shell am start-foreground-service -n com.hamburger.hdrwin/.HdrWindowService \
    -a com.hamburger.hdrwin.START
adb shell am start-service -n com.hamburger.hdrwin/.HdrWindowService \
    -a com.hamburger.hdrwin.STOP
```

### 顺序很重要：先给权限，再点开启

悬浮窗权限没给的时候，`WindowManager.addView()` 会直接抛异常。以前加窗口只在 `onCreate()`
里做一次，所以「**服务已经在跑（只是没有窗口）→ 用户补上权限 → 再点开启**」这条路上，
服务不会重建、`onCreate()` 不会再走，窗口就永远补不出来了。

v1.1.2 起每次 `START` 都会检查一遍窗口在不在，不在就补建。所以现在两种顺序都行。

### 怎么确认它真的生效了

```sh
adb shell dumpsys display | grep -E 'mIsHdrLayerPresent|mHbmMode=|hdrSdrRatio'
#   开：mIsHdrLayerPresent=true   mHbmMode=hdr(0.xx)
#   关：mIsHdrLayerPresent=false  mHbmMode=off
adb shell dumpsys SurfaceFlinger | grep -i hdrwin     # 期望看到 geomBufferSize=[0 0 8 8]
adb shell cat /sys/class/backlight/panel0-backlight/brightness
```

状态变化不是瞬时的，改完等两三秒再读。

**这台机器的 logcat 对第三方 App 是关的（root 读也一样空）**，所以 App 自己往文件里写了一份：

```sh
adb shell su -c 'cat /data/user/0/com.hamburger.hdrwin/files/hdrwin.log'
```

每次开关窗口都会记一行，`showOverlay FAILED` / `bindHardwareBuffer FAILED` /
`setForceHdrEnabled FAILED` 之类一眼就能看到卡在哪。文件上限 64 KB，满了自动重来。

---

## 五、UltraHDR JPEG 是怎么生成的

`Bitmap.setGainmap(Gainmap)` + `Bitmap.compress(JPEG)` —— 就这两句。
框架会自己把 gain map 编码成第二个 JPEG，用 **MPF**（Multi-Picture Format）拼在主图后面，
再往 APP1 里写一段 `hdrgm` 元数据（版本、增益上下限、gamma、epsilon、方向）。
**产出的就是一个普通的 `.jpg` 文件**，不支持的软件看到的是主图，支持的（Google 相册 / 酷安）才读出高光。

生成工具在 [`hdrwin/tools/UltraHdrGen.java`](hdrwin/tools/UltraHdrGen.java)，就是 App 里那段代码的独立版：

```sh
# javac + d8 打成 ultrahdr.jar，推到设备
adb push ultrahdr.jar /data/local/tmp/
# 默认出 8×8 的 ultrahdr_small.jpg；加 --big 出 1080×1080 的 ultrahdr.jpg（给人看的）
adb shell su -c "CLASSPATH=/data/local/tmp/ultrahdr.jar app_process /data/local/tmp \
    UltraHdrGen /sdcard/Download/HDRTest"
```

它会打印 `hasGainmap after set = true`，并同时输出一张**不带 gain map** 的 `plain.jpg` 作对照。
生成的 8×8 那张约 3 KB。

> 只有运行这个**命令行工具**才需要 root（要用 `app_process`）。App 本身完全不需要 root。

---

## 六、自己编译

不用 Gradle，纯手工 `aapt2 / javac / d8 / zipalign / apksigner`：

```powershell
powershell -ExecutionPolicy Bypass -File .\hdrwin\build.ps1
```

依赖：Android SDK `build-tools;36.0.0` + `platforms;android-36` + JDK 17。
路径不对就设 `$env:ANDROID_SDK_ROOT` / `$env:JAVA_HOME`。

产物签名用仓库里自带的 `hdrwin/debug.keystore`（口令 `android`），所以你重新编译出来的包
**可以直接覆盖安装**在同一个包名上。

源码结构：

```
hdrwin/
├── HDR-Brightness.apk                      构建产物（也是发布用的那个）
├── build.ps1                               手工构建脚本
├── debug.keystore                          签名用
├── app/
│   ├── AndroidManifest.xml                 minSdk 34 / targetSdk 36 / theme=@style/AppTheme
│   ├── res/values/strings.xml              应用名
│   ├── res/values/styles.xml               浅色 AppTheme + 强制深色/浅色两份
│   ├── res/values-night/styles.xml         深色 AppTheme（「跟随系统」用）
│   └── src/com/hamburger/hdrwin/
│       ├── MainActivity.java               授权 / 开启 / 关闭 + 深色模式选择
│       └── HdrWindowService.java           核心：造图 → 解码 → 绑 buffer → 悬浮窗
└── tools/
    └── UltraHdrGen.java                    独立的 UltraHDR JPEG 生成器
```

构建是纯手写的，顺序有个坑：代码里引用了 `R.style.AppTheme*`，而 `R.java` 是 `aapt2 link`
生成的，所以**必须先 link 再 javac**（`--java <dir>` 输出 R.java）。顺序是
`aapt2 compile → aapt2 link(+R.java) → javac → d8 → 注入 classes.dex → zipalign → apksigner`。

### 最大的坑：别碰 `resources.arsc` 的压缩方式

`targetSdk >= 30` 之后，**PackageManagerService 拒绝安装 `resources.arsc` 被压缩过的 APK**，
报 `INSTALL_PARSE_FAILED_RESOURCES_ARSC_COMPRESSED`（`-124`）：

```
Targeting R+ (version 30 and above) requires the resources.arsc of installed APKs
to be stored uncompressed and aligned on a 4-byte boundary
```

`aapt2 link` 出来的包本来是对的 —— `resources.arsc` 是 **STORE**、数据偏移 4 字节对齐。
**是后处理把它搞坏的**。实测（`aapt2 link` 原始输出 → 各种后处理之后）：

| 步骤 | `resources.arsc` | 结果 |
| --- | --- | --- |
| `aapt2 link` 原始输出 | STORE, offset 1280 | ✅ |
| 把所有条目用 `CreateEntry(name, Optimal)` 重写一遍 | DEFLATE | ❌ -124 |
| 同上，但 `resources.arsc` 要 `NoCompression` | **还是 DEFLATE** | ❌ -124 |
| `ZipArchiveMode.Update` 只加 `classes.dex` | STORE, offset 1284 | ✅ |

两个反直觉的点：

1. **Windows PowerShell 的 .NET Framework 里，`CreateEntry(name, CompressionLevel.NoCompression)`
   依然会输出 DEFLATE** —— 这个枚举值它不认。所以「重新打包时手动指定不压缩」这条路走不通。
2. **`zipalign` 救不了压缩过的条目** —— 它只调整未压缩条目的偏移，压缩条目它管不着，
   而且照样打印 `Verification successful`。所以 `zipalign` 通过 ≠ 装得上。

结论：**只往 aapt2 的输出里 `Update` 式地加 `classes.dex`，别重建整个 zip**。
`build.ps1` 最后有一道 `Assert-ArscInstallable`：自己按 zip 中央目录把 `resources.arsc`
的压缩方式和数据偏移读出来，不对就直接让构建失败 —— 这个错误只在安装时才会暴露，值得提前拦。

`HdrWindowService` 里保留了两条**兜底路径**（`HardwareRenderer` 和 `lockHardwareCanvas`），
它们是调试早期试错留下的，实测都会丢 gain map、无法触发 HDR，只在绑定失败时兜一下底。

---

## 七、兼容性 / 已知限制

- 需要 **Android 14（API 34）及以上**：`Gainmap`、`SurfaceView.setDesiredHdrHeadroom`、
  `SurfaceControl.Transaction.setExtendedRangeBrightness` 都是 API 34 才有的。
- 需要 ROM 的亮度栈是 AOSP 那一套（`HighBrightnessModeController` + `mIsHdrLayerPresent`）。
  Pixel、HyperOS 都是；其它 ROM 未验证。
- **它只是把上限放开，不强制亮度**：系统滑杆依然有效，只是整体上移了。
- **真的会更耗电、更热**：1300nit 是面板满功率。
- 低电量时会被 `hdr low_battery` 压到约 1200nit（背光 3839），这是系统的保护，App 不去对抗。
- 常驻一条前台服务通知（`IMPORTANCE_MIN`，不响不亮）。
- 没有做「息屏自动收起」，靠 `START_STICKY` 自己回来。

---

## 八、这个仓库以前是什么

这里原本是 **Brightness Boost** —— 一个 Magisk / KernelSU 模块，直接写内核背光节点来上托亮度。
结论是**那条路在这台机器上是死的**：框架每秒把节点写回 2047，抢写会造成约 30Hz 的明暗频闪。
唯一干净的路子就是本文这个「让框架自己放行」，而且**不需要 root**，所以模块整个删掉了。

旧代码在 git 历史里，最后一次完整提交是 `bb419e9`：

```sh
git checkout bb419e9 -- .
```

---

## 九、更新日志

### v1.1.2

- **修掉「给了权限也开不起来」**：加窗口以前只在 `onCreate()` 里做一次，
  服务已经在跑时再点「开启」不会重建服务，窗口就永远补不出来。现在每次 `START` 都补检
- **加了自带日志文件**：这台机器 ROM 把第三方 App 的 logcat 关了（root 读也是空的），
  调试只能靠文件 —— `/data/user/0/com.hamburger.hdrwin/files/hdrwin.log`，上限 64 KB
- 真机实测（小米 13 Ultra / HyperOS OS4 / Android 17，v1.1.2）：
  开 → `mIsHdrLayerPresent=true`、`mHbmMode=hdr(0.52)`、背光 2132、色域仍是 `SRGB (7)`；
  关 → `false` / `off`；再开 → `true`。5 次 × 3 秒采样稳定
- 顺手核对：同一界面 HDR 开和关时截图，背景像素都是 `R=254 G=233 B=230` —— **HDR 不偏色**

### v1.1.1

- **修掉安装失败**：`resources.arsc` 被压成了 DEFLATE，装上报 `-124`。
  构建脚本里那一趟「把所有条目重写一遍」的后处理是罪魁祸首，已删掉
- `build.ps1` 加了 `Assert-ArscInstallable`，以后构建出来就先自检，不合格不让出货
- 代码和资源都没动（`classes.dex`、`resources.arsc` 与 v1.1.0 逐字节相同），只改了打包方式和版本号

### v1.1.0

- 界面加了**深色模式**：跟随系统 / 深色 / 浅色三选一，默认跟随系统
- 主题换成 `NoActionBar` 变体（去掉了重复的系统标题栏）
- 补上 `WindowInsets` 让位，修掉标题被状态栏压住的问题
- `HdrWindowService.java` 未改动，HDR 触发逻辑与 v1.0.0 一致
- ⚠️ 这个版本的包**装不上**（-124），请用 v1.1.2

### v1.0.0

- 首个版本：透明 UltraHDR 小窗触发 HDR 亮度通路，背光 2047 → 3839 / 4095
- 仓库从 Magisk 模块改为纯 APK
- ⚠️ 这个版本的包**装不上**（同一个 -124 缺陷），请用 v1.1.2

---

## 免责声明

长时间 1300nit 会显著增加**烧屏**风险和发热。软件绕不过面板的物理与热保护，本 App 也不去对抗它。
请自行评估后果，作者不对任何硬件损坏负责。

## 许可证

MIT
