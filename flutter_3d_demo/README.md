# 夸克网盘相册 · 3D 回忆故事 Demo

Flutter 3D 技术可行性前置验证 Demo，实现 `docs/` 中《3D 回忆故事 MVP 前期验证开发文档》的
核心体验。相册为真实旅行图库：**632 张照片（501 张含 GPS）、2024.05.03-12 新疆环线**。

提供两种回忆形态：

1. **交互式 3D 回忆空间（带 3D 照片地图）** —— 照片在纵深空间排成环形阵列，左右拖动环视、
   拖动焦点卡查看前后景视差、章节直达；右上角打开**3D 照片地图**：纯 Flutter 2D
   Canvas 软件渲染的 3D 地球仪（纹理球体 + 照片地标牌立在球面上），拖动旋转、双指缩放、
   点按卡片飞往拍摄地；放大越过阈值后交叉淡入**街道级地面平面地图**（OSM/高德栅格瓦片
   + 墨卡托单应投影 + DEM 三维地形隆起），可一路放到街道级；双击/长按该地点进入
   **3D 照片浏览器**（LocationPhotoSpace）。632 个拍摄点以点云铺底。
2. **回忆视频（自动播放）** —— 导演模式按镜头脚本自动播放 88 秒故事（7 章节 22 镜头），
   支持暂停、章节跳转、进度条拖拽与互动镜头视差。

## 3D 地球仪技术特点

- **纯 Flutter 2D Canvas 软件渲染**：无 3D 引擎/库，全部 3D 数学手写（旋转矩阵、透视投影、
  背面剔除、画家算法排序），通过 `Canvas.drawVertices` + `ImageShader` 绘制纹理球体。
- **球→地图无缝过渡**：捏合放大的连续缩放轴上，2.6→3.6 区间交叉淡化，球体模式与地图模式
  共享同一相机朝向（_rotX/_rotY ⇄ 墨卡托中心），过渡不跳变。
- **Google Earth 式 2D/3D 俯仰切换**：地图模式下 55° 倾斜视角 ⇄ 0° 垂直俯视，600ms
  easeInOutCubic 动画，所有瓦片/地标/点云投影自然跟随。
- **离线 DEM 地形**：`assets/terrain.bin` 为 ETOPO1 全球高程数据（1 弧分），3D 倾斜视角
  下每张瓦片 16×16 子网格按真实海拔隆起，含坡向明暗（shade）。
- **GCJ-02 火星坐标转换**：高德瓦片为 GCJ-02 坐标系，照片 GPS 为 WGS-84，切到高德源时
  自动偏移对齐；OSM 瓦片为 WGS-84，源间连续失败自动切换兜底。
- **瓦片 LRU 缓存**：150 张上限（≈37MB），并发 8 路加载 + 160 槽等待队列，失败 30s 不重试。

## 运行

使用官方 Flutter 引擎，推荐 macOS 桌面：

```sh
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
- **交互空间**：3D 环视照片阵列 + 2.5D 分层视差 + 金色粒子 + 章节胶囊 →
  右上角打开 3D 地球仪照片地图（球体 → 街道级地图）。
- **视频模式**：AI 生成页（3D 环绕照片卡 + 阶段进度）→ 沉浸播放器（空间转场、
  空间字幕、片尾卡片收拢成封面）。

## 数据资产

- `assets/thumbs/`：632 张缩略图（长边 512，网格与地图标记用）。
- `assets/photos/`：故事选用的 25 张高清图（长边 1440，播放器与焦点卡用）。
- `assets/earth_dark.jpg`：等距圆柱投影地球纹理（2048px，球体贴图）。
- `assets/terrain.bin`：ETOPO1 全球 DEM（1 弧分 ≈ 1.8km，Float32 栅格，3D 地形用）。
- `lib/story/photo_geo.dart`：由 EXIF 预提取生成的 GPS 表（缺失者按时间序插值，
  属"事件推断位置"）、10 个路线锚点、全程 1322 公里（haversine 累加）。
- `lib/story/place_names.dart`：离线反地理编码地名标注（约 300 个主要城市/景点）。

## 代码结构

```
lib/
  main.dart                         # 入口 + AUTOSTART/START_AT 调试开关
  widgets/phone_stage.dart          # 手机舞台（竖屏比例裁切 + 背景）
  pages/
    entry_page.dart                 # 相册入口（封面 + 照片网格 + 双模式卡片）
    generating_page.dart            # AI 生成页（3D 环绕照片卡 + 阶段进度）
    interactive_story_page.dart     # 交互式 3D 回忆空间（环视 + 视差 + 章节 + 地图入口）
    photo_map_page.dart             # 3D 照片地图入口（薄封装 → photo_map_globe）
    photo_map_globe.dart            # ★ 核心：3D 地球仪 + 街道级地图（2183 行）
                                    #   - 球体：手写 3D 数学 + drawVertices 纹理球体
                                    #   - 地图：墨卡托投影 + 俯视相机 + 瓦片下载/LRU
                                    #   - 地形：DEM 3D 隆起 + 坡向明暗
                                    #   - 地标：GPS→屏幕坐标投影 + 聚合 + 飞行动画
    photo_map_shared.dart           # 照片地图共享类型（PhotoMapMarker 等）
    location_photo_space.dart       # 地点照片 3D 浏览器（卡片堆叠 + 拖拽浏览）
    terrain.dart                    # 离线 DEM 地形加载与采样（双线性插值）
  player/
    story_player_page.dart          # 视频模式播放器：StoryController 主时钟 + 控制条
    story_scene.dart                # 镜头模板/空间转场/卡片环绕/片尾收拢
    spatial_photo.dart              # 2.5D 分层照片卡
    particles.dart                  # 金色光尘粒子
  story/
    story_models.dart               # Story/Chapter/Shot 模型与 Demo Manifest
    photo_geo.dart                  # GPS 数据（EXIF 生成，缺失按时间插值）
    place_names.dart                # 离线反地理编码地名标注
test/
  story_golden_test.dart            # 截图测试：flutter test 后输出 test/shots/*.png
  story_logic_test.dart             # 时间线 / 验收规则 / GPS 数据完整性单测
```

## 验证

```sh
flutter analyze   # 0 issues
flutter test      # 20 个用例全部通过，并生成 test/shots/ 各场景真实渲染截图
```

## 项目背景

本项目为夸克网盘相册的 3D 回忆故事功能前期技术验证，核心目标是验证"在 Flutter 中实现
Google Earth 式的 3D 照片地图体验"是否可行。结论：**可行**。纯 Flutter 2D Canvas
软件渲染方案在 macOS 桌面端已实现 60fps 稳定运行，纹理球体 + 地形 + 街道级瓦片地图
全部通过 `Canvas.drawVertices` 完成，零 3D 引擎依赖，全平台一致。