# 夸克网盘相册 · 3D 回忆故事 Demo

Flutter 3D 技术可行性前置验证 Demo，实现 `docs/` 中《3D 回忆故事 MVP 前期验证开发文档》的
核心体验。相册为真实旅行图库：**632 张照片（501 张含 GPS）、2024.05.03-12 新疆环线**。

提供两种回忆形态：

1. **交互式 3D 回忆空间（带 3D 照片地图）** —— 照片在纵深空间排成环形阵列，左右拖动环视、
   拖动焦点卡查看前后景视差、章节直达；右上角打开**3D 照片地图**：真实地图底图
   （按平台分发：**Android/iOS 用 MapLibre 原生 SDK + OpenFreeMap 免费矢量瓦片**，
   真 3D 俯仰角 55°，无需 API key；**macOS 桌面用 flutter_map + OpenStreetMap
   免费瓦片 + 反色暗化滤镜 + 35° 透视倾斜**；WGS-84 与照片 EXIF GPS 同坐标系无偏移）。
   故事照片以竖立卡片"插"在拍摄位置上，点按卡片相机飞行到拍摄地并联动环视焦点，
   **双击照片弹出大图浏览**（可拖动视差）；632 个拍摄点以点云铺底。
2. **回忆视频（自动播放）** —— 导演模式按镜头脚本自动播放 88 秒故事（7 章节 22 镜头），
   支持暂停、章节跳转、进度条拖拽与互动镜头视差。

## 运行

使用官方 Flutter 引擎（zsh 先执行 `official` 函数切环境），推荐 macOS 桌面：

```sh
official
cd flutter_3d_demo
flutter run -d macos        # 桌面窗口下自动以竖屏手机舞台呈现
```

快捷直达（编译期 dart-define）：

```sh
flutter run -d macos --dart-define=AUTOSTART=interactive   # 直接进交互空间
flutter run -d macos --dart-define=AUTOSTART=generating    # 直接看生成页
flutter run -d macos --dart-define=AUTOSTART=player --dart-define=START_AT=40   # 直达视频第 40 秒
```

## 体验链路

- **入口页**：回忆相册详情（封面 + 632 张照片网格）+ 双模式卡片（进入 3D 回忆空间 /
  生成回忆视频）。
- **交互空间**：3D 环视照片阵列 + 2.5D 分层视差 + 金色粒子 + 章节胶囊 + GPS 路线图。
- **视频模式**：AI 生成页（3D 环绕照片卡 + 阶段进度）→ 沉浸播放器（空间转场、
  空间字幕、片尾卡片收拢成封面）。

## 数据资产

- `assets/thumbs/`：632 张缩略图（长边 512，网格与地图标记用）。
- `assets/photos/`：故事选用的 25 张高清图（长边 1440，播放器与焦点卡用）。
- `lib/story/photo_geo.dart`：由 EXIF 预提取生成的 GPS 表（缺失者按时间序插值，
  属"事件推断位置"）、10 个路线锚点、全程 1322 公里（haversine 累加）。

## 代码结构

```
lib/
  main.dart                        # 入口 + AUTOSTART/START_AT 调试开关
  pages/entry_page.dart            # 相册入口（双模式卡片）
  pages/generating_page.dart       # AI 生成页
  pages/interactive_story_page.dart# 交互式 3D 回忆空间（环视 + 视差 + 章节 + 地图入口）
  pages/photo_map_page.dart      # 3D 照片地图（flutter_map 倾斜投影 + 竖立照片卡 + 相机飞行）
  player/story_player_page.dart    # 视频模式播放器：StoryController 主时钟 + 控制条
  player/story_scene.dart          # 镜头模板/空间转场/卡片环绕/片尾收拢
  player/spatial_photo.dart        # 2.5D 分层照片卡
  player/particles.dart            # 金色光尘粒子
  story/story_models.dart          # Story/Chapter/Shot 模型与 Demo Manifest
  story/photo_geo.dart             # GPS 数据（EXIF 生成，缺失按时间插值）
test/story_golden_test.dart        # 截图测试：flutter test 后输出 test/shots/*.png
test/story_logic_test.dart         # 时间线 / 验收规则 / GPS 数据完整性单测
```

## 验证

```sh
flutter analyze   # 0 issues
flutter test      # 20 个用例全部通过，并生成 test/shots/ 各场景真实渲染截图
```
