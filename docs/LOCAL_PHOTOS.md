# 本机旅行照片（2026-09-23）

默认首页为 Flutter `TravelHomePage`。点击“选择本机照片”多选原图，只保留带有效 EXIF GPS 的照片；无位置的照片直接跳过，不展示、不补位置。点按缩略图选择本次要浏览的照片，再进入回忆空间或 3D 照片地球。右上角“示例模版”保留原新疆首页、照片和视频演示。

## 实现

- `lib/photos/local_photo_library.dart`：Flutter 插件选图和 EXIF 读取；Dart 负责筛选、SHA-256 去重、缩放、原子保存及中断恢复。1920px 预览和 256px 缩略图保存在应用支持目录。选择状态持久化，移除仅删除应用副本。
- `lib/photos/photo_source.dart`：统一提供内置资源与本机文件的图片、缩略图和字节读取。
- `StorySpec.mapPhotos` 将所选照片及真实 GPS 传给地图；本机相册没有固定片尾，所以单张照片和最后一天的照片也保留。空间、地球、地点浏览和地形沿用同一组本机照片。
- `SceneAssets` 为本机图片生成运行时 GPU 纹理；原有 GPU 场景及内置资源继续使用。首页、导入和存储业务均为 Dart，无新增 Kotlin 业务代码。

## 验证

环境：执行 `offical` 后使用官方 Flutter `3.49.0-1.0.pre-76` / Dart `3.14.0-253.0.dev`。设备为 Xiaomi 24129PN74C，Android 16 / API 36，ARM64，Impeller Vulkan。

- `flutter analyze`：通过。
- `flutter test`：29 项通过；10 项 GPU 专用测试在主机跳过。
- 新增真机测试 `integration_test/local_photos_test.dart`：通过。验证真实 EXIF 读入、无 GPS 跳过、重复图片去重、两个本机图片 GPU 场景、末章节保留、空间到地球以及首页到地球的照片传递、文件大图预览、选择状态恢复。
- 系统文件选择器手动验证：选择 3 张有 GPS 的测试照片和 1 张无 GPS 照片，首页显示“已导入 3 张照片；已跳过 1 张无位置信息的照片”，仅展示 3 张缩略图。测试副本的 GPS 由已知坐标写入，未修改手机原图。
- 用户已实际使用并确认没有问题。

普通测试没有代替 GPU 渲染验证；真机日志包含 `GALLERY_GPU_READY photos=2` 和 `GALLERY_GPU_READY earth=16384_triangles`，集成测试结果为 `All tests passed`。本次没有进行新的帧率或大批量照片性能基准测试。

复验命令（先执行 `offical`）：

```sh
flutter analyze
flutter test
ORG_GRADLE_PROJECT_galleryApplicationId=com.example.flutter_3d_demo.verification \
  flutter build apk --profile --target-platform android-arm64 \
  --dart-define=RUN_GPU_TESTS=true -t integration_test/local_photos_test.dart
python3 tool/run_gpu_tests.py --serial <设备地址> \
  --app-id com.example.flutter_3d_demo.verification
flutter build apk --release --target-platform android-arm64
```

切换测试入口与正式入口时保留默认的 pub 步骤，确保生成的插件注册信息同步更新。`galleryApplicationId` 仅用于隔离真机测试；正式 release 包名仍为 `com.example.flutter_3d_demo`。

正式产物：`flutter_3d_demo/build/app/outputs/flutter-apk/app-release.apk`，145.1 MB（Flutter 输出），SHA-256：`bdce22b7812bd58cfaa728e3ed2e8c8847faa110fe92382a5486338b23672fab`。仍使用项目原有的 debug keystore 签名配置。本机签名与手机原演示包不同，用户已授权卸载旧版并安装正式 release 包。

正式 release 已成功安装到该手机并启动；检查确认本机选图、示例模版、回忆空间、照片地球四个入口存在，启动期间无 Flutter / AndroidRuntime 错误日志。最终首页截图为 `/tmp/travel_gallery_verification/release-installed.png`。

验证截图与日志保存在本机 `/tmp/travel_gallery_verification/` 和 `flutter_3d_demo/build/gpu-native-test-log.txt`。主机原本缺少示例缩略图与地球底图，已按既有 `texture_aliases.json` 和 README 来源恢复；现有 100 张照片及原映射未改动。
