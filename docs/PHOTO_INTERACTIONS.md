# 同地点照片折叠与悬浮相册（2026-09-22）

## 当前行为

- 地球与地形把同地点照片折叠成一张叠放卡片，左上角显示总数。双击直接打开玻璃悬浮相册；不同地点的区域分组仍可逐级展开和返回。
- 小幅 GPS 抖动按包围盒对角线不超过 50 米归为同地点。地点作为不可拆分的单位参与区域分组，即使跨过网格边界也保持完整；不会沿着连续步行轨迹链式合并。
- 悬浮相册支持左右滑动、上一张/下一张按钮、双指缩放到 1–5 倍、放大后拖动、双击放大/还原，以及还原按钮。关闭或点击外部返回地图，保留地图视角。
- 翻页和缩放统一由图片的手势控件接收，普通单指拖动交给分页滚动；不同设备触摸阈值不会造成翻页与缩放抢手势。翻页过程中保留缩放控件身份，慢速滑动松手后必须完整停靠。
- 大图通过 `previewAssets` 解析并懒加载，远离当前页的已解码图片会释放。照片空间的固定相机、普通回忆空间的自由环绕、地球星空与真实 GPU 地形继续保留。
- 632 个照片点位使用既有图片替代映射；原图缺失情况和替代关系见 `asset_replacements.json`。本次没有声称恢复缺失原片。

## 复现

在 `flutter_3d_demo` 使用官方 Flutter SDK：

```sh
offical
flutter analyze
flutter test
flutter build apk --profile --target-platform android-arm64 \
  --dart-define=RUN_GPU_TESTS=true -t integration_test/gpu_scene_test.dart
python3 tool/run_gpu_tests.py --serial <当前已占用设备>
flutter build apk --release --target-platform android-arm64 -t lib/main.dart
```

普通主机测试不伪造 GPU 后端；GPU 渲染和地图交互在 Android 真机复验。设备租约及 ADB 地址须实时核验。

## 本次验证

官方 Flutter `3.49.0-0.1.pre`，Android 15 / OPPO PKZ110，Flutter GPU + Impeller Vulkan。

- `flutter analyze` 无问题；主机 24 项通过，10 项 GPU 测试在主机跳过。
- Android profile 真机 12 项测试通过（日志另计 `tearDownAll`）；包含地球/地形折叠相册、慢速翻页完整停靠、相机保留，以及既有 GPU 和地图回归。
- 逻辑测试覆盖全部 632 个点位的分组和数量守恒、90 张同地点照片整组折叠、跨网格边界以及步行轨迹防止链式合并。
- 相册测试同时覆盖默认和低触摸阈值、逐帧慢速滑动并检查完整停靠、双指放大缩小、放大后拖动不翻页、双击、按钮切换及关闭返回。

证据目录：`/tmp/flutter_3d_gallery_album_20260922/`。本次未重新测量性能，之前的性能对照见 `PERFORMANCE_20260922.md`。

## 正式包与截图

正式包入口为 `lib/main.dart`，产物 `flutter_3d_demo/build/app/outputs/flutter-apk/app-release.apk`，153,199,313 字节。

- SHA-256：`0946b918c2f2fbc86e9874eb8eecc4d37450a25c924ec7c0aa00e8fdcc625262`，已安装 APK 的设备端哈希与本地产物一致。
- 官方引擎 `libflutter.so` SHA-256：`2a08ada9d914d58dd98b64fd07e0bf9215d27ec4d51b71afd3ae72b1a6a26145`；`libapp.so` 不含 `GALLERY_FRAME` 探针标记。
- 同一台 OPPO 真机已更新，scrcpy 可见窗口保持运行。交付时 IRMA `bfcf166412c969ec` 核验为当前用户占用；后续使用前仍须重新核验。

证据目录内：

- `analyze.log`、`host-tests.log`、`native-build.log`、`native-tests.log`、`native-runtime.log`：分析与测试记录。
- `release-build.log`、`release-install.log`、`release-receipt.json`、`release-runtime.log`：正式包构建、安装、哈希和运行记录。日志确认 Vulkan、照片/地球/地形 GPU 就绪，以及地形 54 张瓦片加载成功、失败为 0。
- `release-terrain.png`：真实照片地点的叠放卡片。
- `release-album.png`、`release-album-page2.png`、`release-album-zoom.png`：同地点 3 张照片的玻璃相册、慢速滑动到第 2 张并完整停靠、双击放大。
- `release-return.png`：关闭悬浮相册后，地形视角与旗子位置保持不变。

主机和真机均覆盖双指放大、缩小；正式 release 另以 ADB 实际滑动和双击核查画面。未提交、未推送。
