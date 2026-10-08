# Flutter GPU 3D 旅行相册

照片空间、地球、地形和故事镜头使用 `flutter_scene 0.23` + 官方 Flutter GPU / Impeller 渲染。网格具有真实 XYZ 坐标，使用透视相机、深度缓冲和射线点选。照片作为纹理安装在有厚度的相框中；回忆空间支持自由环绕和查看背面，地点照片使用固定相机。照片内容本身没有做三维重建。

## 功能

- Flutter 首页支持多选本机旅行照片，按拍摄日期排列；勾选照片后进入回忆空间或 3D 照片地球。只导入带有效 EXIF GPS 的图片，无位置图片直接跳过，不展示、不推断位置。
- 导入时保存应用内副本和缩略图，重新打开应用仍保留照片及勾选状态。重复图片按内容去重，长按缩略图可预览；移除只删除应用副本，手机原图保留。照片处理在本机完成；近距离高清地图仍需联网。
- 右上角“示例模版”打开原新疆首页，保留原照片资源、632 个示例点位及回忆视频入口。
- 三维玻璃照片空间：圆角透明边缘、柔和照片背景、轻量玻璃控件；左右透明悬浮箭头辅助切换上一张/下一张，首尾禁用对应方向；保留滑动浏览、自由环绕、背面视角、俯仰、缩放和章节跳转。
- 地点照片：固定视角，左右拖动切换照片；双击打开大图预览，支持双指缩放和拖动。
- 纹理地球：球面网格、深度遮挡，背景为 GPU 实例化的低亮度星空；近看会自动加载分级卫星底图。照片按地点聚合为旗子，左上角显示数量；不同地点继续逐级展开；同地点照片折叠为一个带数量的叠放卡片，双击打开玻璃悬浮相册，可左右滑动、双指放大缩小、拖动细节和双击还原。关闭后地图保持原视角。
- 真实 DEM 地形：GPU 高程网格、卫星/标准瓦片、俯视、环绕、缩放和平移；网格范围跟随视野和照片位置扩展，旗杆落到实际网格表面，底图最高 z18。
- 地图手势按当前尺度移动，双指缩放围绕手指中心；抬起一根手指不会切换为旋转。地图视图使用原始渲染分辨率，清晰底图需要联网，支持加载失败后重试。
- 88 秒故事：真实相机穿行、空间照片组合、片尾收拢、暂停、拖动进度及章节切换。

## 运行

本机官方 SDK 切换命令拼作 `offical`。已验证 Flutter `3.49.0-0.1.pre` / Dart `3.14.0-147.0.dev`，不使用本地 Hummer 引擎。

```sh
offical
flutter pub get
flutter build apk --release --target-platform android-arm64
adb -s <设备地址> install -r build/app/outputs/flutter-apk/app-release.apk
adb -s <设备地址> shell am start -n com.example.flutter_3d_demo/.MainActivity
scrcpy -s <设备地址> --tunnel-host=127.0.0.1 --no-audio
```

AndroidManifest 和 macOS Info.plist 已启用 Flutter GPU。`hook/build.dart` 负责纹理预处理，无需重新执行 `flutter_scene:init`。当前真机验收范围是 Android。

## 本机照片

首页点“选择本机照片”，在系统文件选择器中多选原图并确认。照片含 GPS 时才会导入，可从“图片”或手机 DCIM/旅行照片文件夹选择；已抹去位置的图片会跳过。导入后点按缩略图切换勾选，再点底部“回忆空间”或“3D 照片地球”。原示例与本机照片各自使用自己的数据。

界面、导入队列、GPS 筛选、图片缩放和持久化都在 Dart 中。系统选图、EXIF 与目录访问使用 Flutter 插件；无自写 Kotlin 业务代码。应用只申请读取照片中的位置元数据，不获取手机实时定位。副本最长边 1920px，缩略图 256px，保存在应用支持目录；卸载应用会删除这些副本。

## 素材

原始 151 张 JPG 和 3 段视频备份在项目根目录 `.local_assets/originals/`。运行用图片最长边为 1440px，缩略图为 512px；包中包含故事与大图预览所需的 100 张 JPG，不包含视频。632 个照片点位通过 `assets/texture_aliases.json` 的 `previewAssets` 映射到 81 张去重后的预览源图。

```sh
python3 tool/prepare_assets.py
```

632 个缩略图条目中，73 项匹配原文件，38 项匹配同名拍摄文件，521 项用附近地点的现有旅行照片补充。替代照片并不代表该 GPS 点的原始拍摄内容，映射和原图哈希见 [asset_replacements.json](../docs/asset_replacements.json)。GPU 纹理别名去重信息在 `assets/texture_aliases.json`。

地球底图来自 [Three.js r160 的地球纹理](https://github.com/mrdoob/three.js/blob/r160/examples/textures/planets/earth_atmos_2048.jpg)，保存在 `assets/earth_dark.jpg`。DEM 使用仓库已有的 `terrain.bin`，约 830m 网格；放大不会增加原始高程精度。

## 验证与性能

```sh
flutter analyze
flutter test
# 在已占用的 Android 真机执行 GPU 集成测试：
flutter build apk --profile --target-platform android-arm64 \
  --dart-define=RUN_GPU_TESTS=true -t integration_test/gpu_scene_test.dart
python3 tool/run_gpu_tests.py --serial <设备地址>
```

普通单测覆盖时间线、GPS、分组、坐标和入口，包括 632 个点位逐层展开后无遗漏、同坐标及 50 米内 GPS 抖动保持整组折叠、不会沿步行轨迹链式合并，以及悬浮相册的翻页/缩放手势。GPU 用例在真机运行，验证场景/网格复用、相机背面、球面射线、地点相机固定、大图预览、地球和地形旗子展开及返回。主机 flutter_tester 的 GPU shader bundle 加载失败不作为渲染通过证据。

`tool/frame_probe.dart` 是独立的性能入口，普通交付包不含帧日志。支持 `/probe/interactive`、`/probe/globe`、`/probe/terrain`、`/probe/location`、`/probe/player/58` 初始 route；`/probe/globe/2.012` 与 `/probe/terrain/45` 用于复现近距离地球和大范围地形。`tool/collect_frames.py` 采集已打开场景的 UI/Raster 耗时，保留原始帧与内存快照。

详细条件、前后数据和验证边界见 [Android 性能记录](../docs/ANDROID_PERFORMANCE.md)，交互恢复见 [照片交互记录](../docs/PHOTO_INTERACTIONS.md)，地图覆盖、清晰度和手势修复见 [地图修复记录](../docs/MAP_RENDERING.md)。

最新内存/流畅度优化及同机前后数据见 [2026-09-22 性能优化](../docs/PERFORMANCE_20260922.md)。`tool/profile_probe.dart` 提供 profile 模式导航、图片缓存和纹理持有量观测；`profile_memory.py` 记录五轮进出页面及 GC 前后数据，`run_perf_scenarios.py` 执行重复 release 场景。正式入口不包含这些诊断接口。
