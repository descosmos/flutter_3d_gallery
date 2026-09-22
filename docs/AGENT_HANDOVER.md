# 3D 旅行相册交接（2026-09-22）

最新样式要求：回忆空间使用轻薄圆角玻璃卡片和模糊照片背景；地球使用低亮度星空。保留真实 GPU 网格，不退回二维投影。

回忆空间左右增加 48 逻辑像素的透明玻璃悬浮箭头，复用 `_select` 切换上一张/下一张；首尾禁用，快速连点有索引边界保护。该辅助入口只出现在回忆空间，现有滑动、缩放、章节和环绕操作保留。正式包真机已验证 1→2→1、快速连点到第 21 张、首尾禁用及继续滑动；证据在 `/tmp/flutter_3d_gallery_photo_controls_20260922/`。

最新交互要求：地点照片相机固定，拖动只切换照片，双击恢复大图预览。地球与地形的照片按地点聚合为旗子，数量在左上角；不同地点的聚合旗子仍逐级展开；同地点照片必须保持为一张带数量的叠放卡片，双击打开玻璃悬浮相册，左右翻页、双指缩放，放大后拖动细节，双击或按钮还原。相同地点包含包围盒对角线 50 米内的小幅 GPS 抖动，不拆散同地点照片。关闭相册保持地图相机；不同地点返回上一级仍恢复之前的分组、中心和缩放。

地图修复要求：地形覆盖可见地面及照片锚点，不能通过隐藏网格外的旗子掩盖覆盖不足；近距离地球加载高清瓦片；缩放和拖动按离地高度/当前尺度计算，保持手指下地点稳定，抬起一根手指不能突然旋转。验收见 [MAP_RENDERING.md](MAP_RENDERING.md)。

当前工程：`/Users/descosmos/self_projects/flutter/flutter_3d_gallery/flutter_3d_demo`。

最新性能改动和验收见 [PERFORMANCE_20260922.md](PERFORMANCE_20260922.md)：高清照片仅保留当前及相邻已加载项、玻璃控件分组模糊、地图 mip 后台生成、z13+ 网格细分/缓存、远景释放 GPU 地图并保留压缩图。`async_texture.dart` 集中适配 flutter_scene 0.23.0 内部异步实现，依赖已锁定，升级需复验。设备实测为 90Hz，不能因为 min/peak 请求 120 就宣称是 120Hz；PSS、FrameTiming、Dart 分配和 Perfetto 指标分开报告。

生产入口已从手写 Canvas 投影改为 `flutter_scene` + 官方 Flutter GPU：照片是有厚度相框上的纹理网格，地球和 DEM 是真正三维网格，遮挡通过深度缓冲完成。未进行单张照片的三维内容重建。

## 代码入口

- `lib/gpu/photo_space_page.dart`：三维照片环、相机、射线点选与交互。
- `lib/gpu/globe_page.dart`：地球、分组、地点浏览与地形入口。
- `lib/gpu/photo_clusters.dart`、`photo_flags.dart`：以完整地点为最小单位的递归分组、GPU 叠放旗面/数量角标/地点旗杆、不同地点旗面避让。
- `lib/gpu/photo_preview.dart`：玻璃悬浮相册，通过 `previewAssets` 解析大图源文件；懒加载左右分页，缩放时锁住翻页，远离当前页的已解码图片逐步释放。
- `lib/gpu/terrain_page.dart`：DEM 网格、动态覆盖、旗杆与网格的真实交点、地图相机。
- `lib/gpu/map_tiles.dart`、`map_navigation.dart`：共用瓦片坐标/请求去重/LRU、视野覆盖、缩放比例与近距离稳定射线。
- `lib/gpu/story_scene.dart`：故事相机与照片空间；相机转场避开前一张照片。
- `lib/gpu/scene_assets.dart`：纹理持有/释放、相框几何、球体几何与渲染设置。
- `lib/gpu/gallery_math.dart`、`gcj02.dart`：坐标和分组。
- 原 pages/player 入口保留为兼容封装；禁止重新接回 2D 投影作为生产渲染。

## 构建与资产

执行 `offical` 后使用官方 Flutter `3.49.0-0.1.pre`，引擎内容哈希 `b99d69481f3d6746880e2b7f59968b53f0d7fc8c`。Android/macOS 已开启 Flutter GPU。不要改为 Hummer SDK。

`hook/build.dart` 是已定制的构建钩子，按 `assets/texture_aliases.json` 生成压缩 GPU 纹理。无需重跑 init。原图与视频完整备份在根目录 `.local_assets/originals/`；运行图片与替代关系由 `tool/prepare_assets.py` 生成。素材详情见 README 和 `asset_replacements.json`。

## 验证约定

- 普通 `flutter test` 不会伪造 GPU 渲染；GPU 测试使用真实 Android profile 包及 `tool/run_gpu_tests.py`。
- 渲染检查必须同时看截图与日志，等 `GALLERY_GPU_READY` 后采集。加载占位不算渲染通过。
- FrameTiming 的 UI/Raster 时间不是屏幕呈现 FPS；静止场景无新帧是按需渲染行为。
- 性能对照的基线为本轮真 3D 初版，记录设备、素材、刷新率、采样帧数和窗口；换设备不混作同机数据。
- 照片空间与故事的渲染比例为 0.75；地球和地形为 1.0，Flutter UI 始终为设备原分辨率。地形静态坡面光照烘焙为顶点色，网格仍走真实 GPU 透视/深度测试；此前的帧耗时表不能作为本次地图改动的性能结论。
- 相框正面使用镂空边框，照片后方没有近乎共面的前板，避免远处出现深度条纹。

运行与性能证据见 [ANDROID_PERFORMANCE.md](ANDROID_PERFORMANCE.md)，交互恢复验收见 [PHOTO_INTERACTIONS.md](PHOTO_INTERACTIONS.md)。IRMA 占用和 ADB 地址均需实时复核；旧 Pixel 7 Pro 租约已结束，禁止再操作。交付设备以记录中的最新核验为准。未提交、未推送。
