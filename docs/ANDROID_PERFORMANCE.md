# Android 真 3D 验证记录（2026-09-22）

本记录中的帧耗时和 APK 信息对应首次真 3D / 玻璃样式验收。之后恢复的固定地点视角、分层照片旗子及大图预览，见 [PHOTO_INTERACTIONS.md](PHOTO_INTERACTIONS.md)；下列性能数值没有重新用于宣称新增交互的性能。

当前已改为 Flutter GPU / Impeller 的真实网格渲染，包含照片空间、地球、DEM 地形和故事相机。按用户最新意见，照片空间使用圆角玻璃卡片、模糊照片背景和轻量玻璃控件，地球使用低亮度星空。照片内容是纹理，不是单张照片的三维重建。

## 验证平台

- 官方 SDK：`/Users/descosmos/projects/flutter/offical/flutter`，本机通过 `offical` 切换。
- Flutter `3.49.0-0.1.pre` / Dart `3.14.0-147.0.dev`。
- Framework revision：`394eedf490a6e99770c816d5c3a2f60dca9787a4`；engine content hash：`b99d69481f3d6746880e2b7f59968b53f0d7fc8c`。
- 渲染库：`flutter_scene 0.23.0`。Android 日志已确认 `Using the Impeller rendering backend (Vulkan)`，支持 ASTC / ETC2 纹理。
- 初期对照设备为 Pixel 7 Pro / Android 14 / 1080×2340 / 120Hz。其租约结束后不再操作；一次 Pixel 7 连接失败申请已释放。
- 最终验证及交付设备：OPPO PKZ110 / Android 15 / 1080×2378，IRMA symbol `bfcf166412c969ec`，流水 `PAZB-7751326`，ADB `30.103.238.12:24059`，硬件序列号 `3B658M01J2700000`。信息仅对本次有效。

## 真 3D 的证据

照片与相框是具有 XYZ 顶点、厚度和法线的网格。透视相机改变真实位置，射线测试命中场景几何；地球和地形使用深度缓冲遮挡。地球为 16,384 个三角形，地形每个瓦片 16×16 网格，Y 来自 DEM。星空为单组实例化星体。

截图检查了相框正面/背面、圆角玻璃样式、地球与星空、卫星地形、三维故事镜头。相框正面不再有与照片共面的整块板，修复远处条纹；播放器加大镜头间距并让相机转场绕过前一张照片，避免被旧照片遮住。

## 性能方法与范围

使用独立 release 入口 `tool/frame_probe.dart`，记录 FrameTiming；交付入口 `lib/main.dart` 没有探针。图片就绪后采样，首尾各裁去 1 秒。拖动用 ADB 650ms 的水平滑动，间隔约 1.6 秒。scrcpy 保持相同 1440px / 30fps 参数。测量时设备固定 120Hz；这些是 UI/Raster 帧耗时，不是屏幕呈现 FPS。

最初真 3D 版本采用全分辨率连续渲染。优化采用 0.75 渲染比例（Flutter UI 保持原分辨率）、按需重绘、GPU 纹理去重与释放、视锥裁剪、地形顶点光照预烘焙。静止照片页 6 秒观察窗内记录到 0 个新帧。

### Pixel 7 Pro 阶段对照

同一台设备、相同素材、21 张照片、13 次滑动、22 秒采样。基线为本轮真 3D 初版。原始帧数 1168 / 1635，裁剪后时间跨度 19.48 / 16.97 秒；按需重绘使静止阶段不再产生帧。

| 指标 | 基线 | 优化后 | 差值 | 变化率 | 目标 |
|---|---:|---:|---:|---:|---:|
| UI P95 (ms) | 16.185 | 4.811 | -11.374 | -70.3% | <16.67 |
| Raster P95 (ms) | 16.076 | 6.121 | -9.955 | -61.9% | <16.67 |

超过 16.67ms 的阶段耗时比例从 4.110% 降到 0.367%。操作后单次 PSS 快照为 367,968 / 347,118 KB，约 -5.7%；这不是长期峰值内存结论。此阶段尚未采用最终玻璃样式，不能把该提升比例当作最终样式的同机结果。

### 最终 OPPO 验证

| 场景 | 样本帧数 | 裁剪后跨度 | UI P95 (ms) | Raster P95 (ms) | 超过16.67ms |
|---|---:|---:|---:|---:|---:|
| 玻璃照片空间 | 1022 | 12.29s | 3.999 | 9.117 | 0.098% |
| 星空地球 | 389 | 10.17s | 4.206 | 3.306 | 0.000% |
| 地形 | 636 | 16.59s | 3.275 | 3.273 | 0.000% |
| 播放器 | 1288 | 14.13s | 6.211 | 5.265 | 0.000% |

玻璃界面增加了透明材质和局部背景模糊开销；当前达到 60Hz 帧预算的目标，不能宣称全部场景稳定 120fps。OPPO 数据与 Pixel 数据分开记录，不混作同机前后对比。

## 测试与产物

- `flutter analyze`：无问题。
- 普通 `flutter test`：11 项通过，3 项 GPU 用例留给真机。
- 真实 Android profile 集成测试验证：网格复用/相机背面、球面射线/捏合、地点照片数量/返回。
- 主机 flutter_tester 无法解包 GPU shader bundle，其图像不作为渲染通过证据；真机使用真实 Vulkan 后端。
- release 构建：`offical && flutter build apk --release --target-platform android-arm64`。
- 交付 APK：`flutter_3d_demo/build/app/outputs/flutter-apk/app-release.apk`。

Maven 官方引擎库与合并阶段 libflutter.so 的 SHA-256 为 `2de326a3dfba2bb5d52fdc1c4912a86b1333238dce401253fc57499708a25941`。AGP 去除调试符号后，APK 内引擎库为 `2a08ada9d914d58dd98b64fd07e0bf9215d27ec4d51b71afd3ae72b1a6a26145`，与 stripped_native_libs 中间产物一致。

## 素材与边界

保留了用户提供的 151 张原图和 3 段视频。生成 25 张故事用图、632 个缩略图条目，其中 521 项使用就近旅行素材补充；映射及原图哈希见 `asset_replacements.json`，不冒充原始照片恢复。地球底图来自 [Three.js r160](https://github.com/mrdoob/three.js/blob/r160/examples/textures/planets/earth_atmos_2048.jpg)。

DEM 约 830m 分辨率，覆盖当前旅行区域；近距离看不到不存在于原始数据中的细节。卫星/标准底图依赖网络；山区标准图可能为空白底色，因此默认卫星。当前真机验收范围是 Android，未声称完整跨平台验收。

全部原始日志、JSON、截图和中间 APK 在 `/tmp/flutter_3d_gallery_perf_20260922/`。最终设备和 scrcpy 保留给用户查看，后续须重新核验租约。未提交、未推送。

最终 APK SHA-256：`996792dddd6cbb57bbd915bfa6a7a734f6cbdd601155a33d16982c141fe43c92`；大小 124,436,158 字节。最终玻璃/星空样式的 3 项 GPU 真机集成测试已全部通过，交付设备恢复了测试前的刷新率设置。
