# AGENT_HANDOVER.md · 夸克网盘相册 3D 回忆 Demo 交接

> 写给接替的 agent：本文档是项目唯一权威交接文档，包含项目现状、架构、全部实测踩坑记录与操作方法。
> 最后更新：2026-08-28（三维地形定版 + release 部署定论）。接手请先读第 0、5、9 节。
> 项目根目录：`/Users/descosmos/self_projects/flutter/flutter_3d`，代码在 `flutter_3d_demo/`。

---

## 0. 一分钟上手（当前状态速览）

- **这是什么**：验证 Flutter 3D 技术在夸克网盘相册「回忆」场景可行性的 demo。素材是 632 张真实新疆旅行照片（2024.05.03-12，501 张含真实 EXIF GPS，其余按时间序插值）。
- **两大模式**：入口页底部卡片两个按钮 → ①「进入 3D 回忆空间」（交互式浏览）②「生成回忆视频」（AI 生成页→导演模式播放器，88s 7 章 22 镜头自动播放）。
- **核心亮点（3D 照片地图）**：自绘 3D 地球仪 → 连续放大 → 55° 倾斜飞行视角真实瓦片地图（街道级 z17.5）→ Google Earth 式 2D/3D 俯仰切换 + 标准/卫星图层切换 + **DEM 三维地形（山体真实隆起+坡向明暗）**；632 张照片全量地标牌（地点级稳定聚合+数量徽标），双击/长按进 3D 环形照片浏览器。
- **当前部署**：release 包已装在模拟器（emulator-5554, Pixel_6_Pro）和真机（fc6e1529, 小米 24129PN74C）上。**必须用 release，debug 会 OOM 闪退（见 5.1）**。
- **质量线**：`flutter analyze` 0 issues；`flutter test` 32/32 全绿。
- **环境**：Flutter 官方 master（`~/projects/flutter/offical/flutter`，3.48.0-1.0.pre-334，PATH 已指向）；Android SDK 在 `~/Library/Android/sdk`。

## 1. 运行与部署（命令级）

```sh
cd /Users/descosmos/self_projects/flutter/flutter_3d/flutter_3d_demo

# 质量检查（每次改动后必跑）
flutter analyze          # 必须 0 issues
flutter test             # 32 个用例；story_golden_test 输出真实渲染截图到 test/shots/*.png

# 部署到模拟器（唯一验证平台，一律 release）
flutter run -d emulator-5554 --release
# 或：flutter build apk --release && adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-release.apk

# 安装到真机（小米，已授权 USB 安装）
adb -s fc6e1529 install -r build/app/outputs/flutter-apk/app-release.apk
adb -s fc6e1529 shell monkey -p com.example.flutter_3d_demo -c android.intent.category.LAUNCHER 1

# 播放器调试直达（macOS 才用，验证不在 macOS 做）
flutter run -d macos --dart-define=AUTOSTART=interactive|generating|player --dart-define=START_AT=40
```

**模拟器死了/卡死**（adb shell 无响应、flutter run 空日志）：

```sh
pkill -f 'qemu-system.*Pixel_6_Pro'
~/Library/Android/sdk/emulator/emulator -avd Pixel_6_Pro -gpu swiftshader_indirect -dns-server 8.8.8.8 &
adb wait-for-device
# 等 getprop sys.boot_completed = 1
```

**adb 验证套路**：截屏 `adb -s emulator-5554 exec-out screencap -p > /tmp/x.png`（不受 Mac 锁屏影响）→ 用 Read 工具看图。导航坐标（模拟器 1440x3120）：进 3D 回忆空间 `input tap 720 2643` → 5s → 地图按钮 `input tap 1318 178`（不灵就再点 (1312,181)）。真机 1200x2670：按相对位置换算（600,2262 / 1098,232）。

## 2. 功能现状（已实现清单）

1. **入口页**：封面 + 632 张网格 + 双模式卡片。
2. **3D 回忆空间**（`interactive_story_page.dart`）：故事精选 22+ 镜头环形阵列，拖动环视+惯性吸附、点击聚焦、焦点卡 2.5D 分层视差、章节胶囊、金色粒子。**这是"整个回忆"的全部精选照片（跨地点），不要与地图的地点浏览器混淆。**
3. **回忆视频**：`generating_page.dart`（AI 生成页）→ `player/`（导演模式播放器：dollyIn/parallaxPan/microOrbit/focusPull/cardSpace/staticParticles/converge 镜头模板、空间转场、字幕、章节刻度、片尾收拢封面）。
4. **3D 照片地图**（`photo_map_page.dart` → `photo_map_globe.dart`，全平台统一纯 Flutter，零原生地图 SDK）：
   - **球体模式（zoom<2.6）**：drawVertices 网格球 + `assets/earth_dark.jpg` 深蓝纹理 + limb 暗化 + 大气辉光 + 星空；拖动轨迹球旋转+惯性、静置极缓自转（zoom<1.3 且未交互）；地名标签（`place_names.dart` 8 个 Nominatim 反查锚点，zoom≥1.6 渐入）。
   - **连续过渡（2.6-3.6）**：球体朝向与地图中心是同一状态的两种读法（centerLat=rotX°, centerLng=-rotY°），交叉淡化无跳变；缩放映射 z = 4.4+(zoom-3.0)×2.62（zoom 8.0 = z17.5）。
   - **地图模式（blend>0.5）**：`_MapCam` 南偏俯视单应（project/unproject 解析式），逐瓦片 drawVertices；拖动=沿地面精确跟手平移+惯性；双指=焦点锚定续放大；瓦片双源（OSM 主源被限流 / 高德备用）+ LRU 缓存 + 手动/自动切源。
   - **Google Earth 式按钮簇**（右下）：2D/3D 俯仰切换（600ms 动画 55°⇄0°，中途可折返）、图层切换（高德 style=7 标准 ⇄ style=6 卫星，仅高德源显示）、切源钮（OSM⇄高德）。
   - **三维地形（tilt>15° 启用）**：`terrain.dart` + `assets/terrain.bin`（7.77MB DEM，覆盖 lat 37.9-49.4/lng 80.7-100.2，2601×1494 网格 830m）。每瓦片 16×16 高程位移子网格（LRU 240），坡向明暗（东南来光），画家算法远→近；垂直夸张 1.5×；hRef 基准面防高海拔相机钻山；2D（tilt=0）自动退化平面快速路径。
   - **照片地标牌（全部 632 张）**：非故事照 storyIndex=-1（不联动故事焦点）；rep 优先级 焦点>故事>普通。聚合策略随 blend 切换：球体模式屏幕距离 48px 聚合（全景 600+ 大组，逐层拆分）；**地图模式地理网格聚合（`_clusterGridDeg=0.02°`≈2km）——同一地点永远一张卡（徽标=全组照片数），缩放/平移/俯仰都不拆不合**（632 张分成 94 个地点组）。
   - **地点照片浏览器**（`location_photo_space.dart`）：双击或长按地标卡打开；该地点照片 3D 半环阵列（拖动环视+惯性吸附+SpatialPhotoCard 2.5D 视差）；地图模式地点组**全量传入**（实测 90 张流畅），球体全景大组等距抽样上限 60；顶部地名取最近 placeLabels 锚点（1.5° 外兜底"拍摄地"）；点空白关闭。
   - 632 张 GPS 点云两种模式都铺底（高德源时连点云也 wgs2gcj）。

## 3. 架构与关键机制

```
lib/
  main.dart                        # AUTOSTART/START_AT 调试开关 + PhoneStage 舞台
  pages/entry_page.dart            # 相册入口
  pages/generating_page.dart       # AI 生成页
  pages/interactive_story_page.dart# 3D 回忆空间（整个回忆的精选照片，跨地点）
  pages/photo_map_page.dart        # 地图入口（转发 GlobePhotoMap）
  pages/photo_map_globe.dart       # 核心：球体/瓦片地图/地形/地标/聚合/手势（~1500 行）
  pages/terrain.dart               # DEM 加载（terrain.bin）、双线性高程、坡向明暗
  pages/location_photo_space.dart  # 地点照片 3D 浏览器
  pages/photo_map_shared.dart      # PhotoMapMarker/MapHeader/MapHint/PhotoPeekOverlay(已不被地图页用)
  player/                          # 回忆视频播放器（story_player_page/story_scene/spatial_photo/particles）
  story/story_models.dart          # Story/Chapter/Shot + demoStory（新疆环线 88s 7章）
  story/photo_geo.dart             # 632 张 GPS（EXIF 生成，WGS-84）
  story/place_names.dart           # 8 个地名锚点（开发期 Nominatim 反查固化）

test/
  story_logic_test.dart            # 故事结构/GPS 完整性
  story_golden_test.dart           # 页面截图（test/shots/）
  globe_gesture_test.dart          # 地球仪黑盒手势（旋转/双击/捏合/地图模式/2D-3D/地形/徽标稳定）
  location_photo_space_test.dart   # 地点浏览器 4 例
  widget_test.dart                 # 模板默认
```

**数据流**：故事页 `_buildMapOverlay` 传故事 markers → GlobePhotoMap 内 `_rebuildAllMarkers` 以 photoGeo 632 条为底合并（thumbAsset→storyIndex 映射，其余 -1）→ 球体模式屏幕聚合 / 地图模式 `_GeoGroup` 地理网格 → `_LandmarkLayout`（members/rep/锚点/深度）→ 画笔（旗杆）+ Widget（卡片）。

## 4. 测试体系要点

- 32 个用例：`story_logic`（结构/GPS）+ `story_golden`（页面截图）+ `globe_gesture`（地球仪黑盒手势）+ `location_photo_space`。
- 截图证据：`flutter test test/story_golden_test.dart` 后看 `test/shots/*.png`（macOS 宿主渲染，与 Android 一致）。
- 修行为必须同步改测试；globe_gesture 的用例命名即行为规格书。

## 5. 坑与方法论（全部实测，最重要）

### 5.1 内存 / 构建模式
- **debug 跑地球仪必 OOM 闪退（定论）**：debug 运行时（VM debug+JIT+observatory+finalizer 慢）叠加瓦片/纹理缓存内存失控，qemu 都会整机被杀（本会话多次"模拟器暴毙"的根因）。**release 实测健康**：PSS 基线 73MB → 球体 97 → 地图+高德 130 → 拖动×20 回落 128 → 照片空间/2D3D 往返持平。**验收一律 `--release`**（70.3MB，debug 包 138MB）。
- 测量方法：`adb shell dumpsys meminfo com.example.flutter_3d_demo`（看 TOTAL PSS/Native Heap/EGL+GL mtrack）+ 宿主机 `ps -o rss= -p $(pgrep -f qemu-system)`。

### 5.2 构建环境
- **NDK r28c 曾卡死构建**：根因是旧 maplibre 依赖的 `jni` 插件写死 `flutter.ndkVersion`（28.2 未装），sdkmanager 经代理下载被 MITM 截断。解法（仍在 `android/build.gradle.kts`）：所有模块 ndkVersion 统一反射覆盖为已装 27.2.12479018（`evaluationDependsOn(":app")` 会提前评估 :app，需按 `state.executed` 分支）。**现 maplibre 已移除，此机制仅作保险**。
- **Gradle 依赖下载**：daemon 自动继承 macOS 系统代理（与 shell env 无关），大文件被截断 → `android/build.gradle.kts` 与 `android/settings.gradle.kts` 的 repositories 首位是阿里云镜像（maven.aliyun.com/repository/{google,central,public,gradle-plugin}）。
- **小米/HyperOS 拦 adb 安装**（INSTALL_FAILED_USER_RESTRICTED）：需开发者选项开「USB 安装」；否则 push APK 到 /sdcard/Download 手动装。

### 5.3 渲染技术
- **`Canvas.drawVertices` 纹理坐标是图像像素空间**（着色器本地坐标），不是归一化 UV！传 0..1 会贴成左上角单色（排查过整轮）。顶点色与 shader 的混合由 blendMode 控制（modulate=相乘，limb 暗化/地形明暗都用它）。高效传参用 `ui.Vertices.raw`（工厂构造收 List 是另一套）。
- **捏合 `details.scale` 是相对手势起点的累积值**——必须手势开始缓存 `_zoomAtStart`，每事件 `_zoom=_zoomAtStart*scale`（曾当增量复利，手感"窜"）。
- **地球→地图连续性**的关键设计：球体朝向与地图中心共用 `_rotX/_rotY`（centerLat=rotX°, centerLng=-rotY°），无需同步；地标位置在两套投影间 lerp。
- **地形 hRef 基准面**：相机几何相对中心点地表海拔，否则高海拔地区街道级相机"钻山"、地标全被裁剪。

### 5.4 瓦片与地理数据
- **OSM 被限流**：出口 IP 被封，HTTP 200 也返回 "Access blocked" 占位图（状态码检测不出）→ 地图页右下有手动切源钮；自动兜底只对传输层失败生效。
- **高德瓦片**：`webst0{1-4}.is.autonavi.com/appmaptile`（注意是 webst 不是 webrst）。**style=7 不透明标准图、style=6 不透明卫星 JPEG、style=8 是透明路网叠加层（别当底图）**。请求要带自定义 UA。
- **高德系 GCJ-02 坐标**：叠 WGS-84 数据（地标/点云/相机中心）必须 wgs2gcj，否则街道级偏几百米；反向（写回/采 DEM）用粗逆 gcj2wgs。
- **DEM 管线**：Terrarium `s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png`（免 key，h=r*256+g+b/256-32768）z9 批量 curl → PIL 拼接重采样 → int16 LE 二进制（48B 头）。自检基准：艾丁湖 -155m（实 -154）、赛里木湖 2072m（实 2073）。

### 5.5 adb 注入与模拟器
- **无法注入多点触控**（捏合只能靠 widget 测试覆盖）；**双击时序不可靠**（改用 `input swipe x y x y 900` 注入长按，产品上也支持长按打开照片空间）；`sendevent` 非 root 无权限。
- **金框定位点按法**（点聚合组）：截屏 → numpy 找 #FFD88A 质心（<2s）→ 即截即点（球体自转会跑目标）。
- **模拟器 qemu 反复死因 = debug OOM**（见 5.1），release 后基本稳定；仍偶发 adbd 卡死用第 1 节冷启法。
- 模拟器里有不相干 app「Dart MCP Debugger Demo」会污染 logcat，注意甄别。

### 5.6 Widget 测试技法
- 图片真实解码：先 `pump()` 构建出组件，再 `tester.runAsync(() => Future.delayed(...))`。
- 有常转 Ticker 的页面（粒子/自转/惯性）**禁止 pumpAndSettle**，用定时 pump。
- 本 SDK 的 WidgetTester 已移除 `doubleTap`：两次 tapAt + `pump(kDoubleTapMinTime)` 让双击计时器到期，否则报 "Timer is still pending"。
- 拖动手势要**多小步 moveBy**：单 move 事件的 delta 会被识别器当跨 slop 事件吞掉。
- 合成捏合双指交替 moveBy 有系统性焦点漂移：大跨度导航改用点按飞行，地图模式内捏合（精确单应锚定）才用于缩放断言。
- CJK 字体在测试环境缺字形：不断言文本渲染（find.text 找得到但截图是豆腐块，属正常）。

## 6. 已知问题与待办（按价值排序）

1. **街道级地平线 LOD**：`maxFar`（6.5 瓦片）是平面模型遗产，z15+ 远处山体不绘制呈黑色"虚空"，地形隆起后更显眼。解法：远场粗 z 层 LOD。
2. **同坐标连拍永不拆分**：地理网格聚合下同一点位永远一组（产品语义正确），如需看组内照片只能进 LocationPhotoSpace。
3. **大聚合组飞行目标=质心**：600+ 大组质心落在照片稀疏区，点两次后首屏偏空需手动拖到密集簇。
4. **混合带低缩放档（z5-9）相邻地点组屏幕堆叠**（不再按屏幕距离合并），放大即散开。
5. **高德卫星 z17 偏远地区无数据**（灰图），街道级卫星观感受数据源限制；标准样式正常。
6. **830m DEM 网格偏平滑**：近景细沟不如 Google Earth（<100m 数据）锐利，属 8MB 预算取舍。
7. **OSM 源默认开启时需手动切高德**（限流白图）。
8. **故事页 focus 级联切换会触发多次地图飞行**（didUpdateWidget 连锁），与 focus 跟随逻辑同源，未改。
9. 未实测：真机 profile/release 帧率（模拟器软渲染不代表真机）；蜂窝网络下瓦片表现。

## 7. 数据资产

- `assets/photos/`：故事精选 25 张高清（1440px）。`assets/thumbs/`：632 张缩略图（512px）。
- `assets/earth_dark.jpg`：229KB 深蓝 equirectangular 球体纹理（three.js earth_atmos_2048 经 PIL 暗色化：降饱和 0.55/亮度 0.85 → autocontrast → colorize #04090f/#173350/#8fb4d4）。
- `assets/terrain.bin`：7.77MB DEM（见 5.4 管线；重生成照管线跑即可，注意 pubspec 已注册）。
- `lib/story/photo_geo.dart`：632 张 GPS（EXIF 36867/GPS IFD 提取，无 GPS 按时间序线性插值；重跑管线：PIL `getexif().get_ifd(0x8825)`，tag 1/2=纬 3/4=经）。
- `lib/story/place_names.dart`：8 个地名锚点（Nominatim `reverse?format=jsonv2&zoom=10-14&accept-language=zh` 反查，自定义简洁 UA——带 URL 的 UA 会被 Access denied，间隔 ≥1s）。

## 8. 工作约定（用户明确要求，必须遵守）

1. **任务尽量交给 subagent 完成**（用户 2026-08-27 指示）：探索用 explore、实现用 coder、独立任务并行派发；主线程只做协调、验收、关键决策和小修小补。委派 prompt 必须自包含（子 agent 零上下文）：给路径、给已验证结论、给验收命令。子 agent 超时用 resume 续跑，不要重开。
2. **测试验证一律在 Android 模拟器（emulator-5554, Pixel_6_Pro）**（用户 2026-08-27 指示），不用真机、不用 macOS；**部署一律 release**（见 5.1）。真机仅按用户要求安装交付（当前 fc6e1529 已装 release）。
3. **验收闭环**：每项改动 = analyze 0 + test 全绿 + adb 截图读图确认 + 应用停在可展示状态 + 更新本文档。临时文件（/tmp 截图日志）随手清理。
4. 不做用户没要求的事；改动最小化；代码注释用中文、风格随现有文件。

## 9. 文档维护约定

- 本文档是唯一交接文档：完成功能/踩坑/约定变化后**同步更新**（历史已证明多次靠它续命）。保持"当前状态"与"历史留档"分离，过时内容压缩为一行留档或删除。
- 原始产品/技术参考：`docs/` 下有需求 PDF、效果图、`3d_gallery_plan.md`（四个场景的数据需求分析）、`google_earth.jpg`（用户给的 2D/3D 切换参考图）。

---
*本文件由多轮 agent 协作维护。上一棒：2026-08-28 完成三维地形、地点稳定聚合、release OOM 定论。*
