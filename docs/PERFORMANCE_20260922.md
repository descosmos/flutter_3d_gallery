# 回忆空间与照片地球性能优化（2026-09-22）

本轮以当前玻璃界面、悬浮按钮、分层照片旗子和高清地球为基线，保留照片分辨率、地图级别、渲染比例及交互。没有把此前版本的性能记录作为本轮基线。

## 改动

- 回忆空间只让当前及相邻照片持有已加载的高清纹理，远处照片恢复为原缩略图；切换到前景仍加载 1440px 高清图。重复源图不会提前释放，加载中的旧任务不会重新挂回过期材质。
- 两侧按钮和底部玻璃控件分别共用 BackdropGroup，保留原模糊强度及透明度，减少重复的背景采样。
- 地球近景的缩小级别生成改到后台 isolate；仍调用相同 SDK 算法、能力检查、上传和采样设置。
- z13 及更近的球面瓦片使用较少网格并缓存几何，纹理级别/分辨率不变；近景不提交已被裁剪的星空。
- 回到地球远景后，延迟释放高清图层、GPU 瓦片和几何，只保留有界的压缩图片缓存以支持返回。拖回已有覆盖区时取消过时的图层替换请求。

## 条件与口径

OPPO PKZ110 / Android 15 / 1080×2378，官方 Flutter 3.49.0-0.1.pre、flutter_scene 0.23.0、Impeller Vulkan。min/peak 设置虽请求 120Hz，系统实际仍是 90Hz，FrameTiming 时间戳间隔约 10.965ms；本报告不声称测得 120fps。

正式前后对比使用 release 探针：每场景 3 次，每次 22 秒，固定滑动/点击次数，首尾各剔除 1 秒；初始化场景不额外等待、也不裁剪。PSS 在操作后静置 3 秒读取，不是峰值。统计取三次结果的中位数。Perfetto 单独采集，不混入正式帧时间对比。

profile 诊断另做两次预热，记录 GC 前后 Dart 内存与共享纹理持有量，并重复五轮进出页面；它与 release 的 PSS 不混算。9 项真实 GPU 回归测试通过，含高清缓存预算、当前照片分辨率、近景释放及恢复、原地图/照片交互。

验收目标：原画质及交互通过验证；热点高清纹理缓存低于 12 MiB；主要瓶颈的帧耗时和活跃页面 PSS 有实测收益；按实际 90Hz 检查 11.11ms 帧预算。小幅波动或未测项目单独标明。

## Release 对比

| 场景 | 指标 | 基线 | 优化后 | 差值 | 变化率 | 判断 |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| 回忆空间滑动 | UI P95 / ms | 4.393 | 4.593 | +0.200 | +4.6% | 小幅增加，整体瓶颈仍下降 |
| 回忆空间滑动 | Raster P95 / ms | 9.520 | 6.626 | -2.894 | -30.4% | 改善 |
| 回忆空间滑动 | PSS / MiB | 343.641 | 317.505 | -26.136 | -7.6% | 改善 |
| 回忆空间循环切图 | UI P95 / ms | 6.567 | 6.819 | +0.252 | +3.8% | 小幅增加，整体瓶颈仍下降 |
| 回忆空间循环切图 | Raster P95 / ms | 7.734 | 6.537 | -1.197 | -15.5% | 改善 |
| 回忆空间循环切图 | PSS / MiB | 388.146 | 309.834 | -78.312 | -20.2% | 改善 |
| 地球远景拖动 | UI P95 / ms | 4.089 | 4.157 | +0.068 | +1.7% | 小幅波动 |
| 地球远景拖动 | Raster P95 / ms | 3.247 | 3.256 | +0.009 | +0.3% | 小幅波动 |
| 地球远景拖动 | PSS / MiB | 288.798 | 286.408 | -2.390 | -0.8% | 变化小，不认定为内存收益 |
| 地球高清近景拖动 | UI P95 / ms | 5.826 | 5.306 | -0.520 | -8.9% | 改善 |
| 地球高清近景拖动 | Raster P95 / ms | 3.793 | 3.490 | -0.303 | -8.0% | 改善 |
| 地球高清近景拖动 | PSS / MiB | 327.989 | 325.479 | -2.510 | -0.8% | 变化小，不认定为内存收益 |
| 地球初始化后拖动 | UI P95 / ms | 5.270 | 5.250 | -0.020 | -0.4% | 小幅波动 |
| 地球初始化后拖动 | Raster P95 / ms | 3.720 | 3.807 | +0.087 | +2.3% | 小幅波动 |
| 地球初始化后拖动 | PSS / MiB | 330.434 | 331.167 | +0.733 | +0.2% | 变化小，不认定为内存收益 |

各场景最慢阶段 P95 均小于实际 90Hz 的 11.11ms 帧预算。照片滑动的最慢阶段 P95 从 9.520ms 降到 6.833ms（-28.2%）；循环切图从 7.947ms 降到 7.364ms（-7.3%）。这是 UI/Raster 耗时，不是最终呈现 FPS。

数据：`baseline/controlled/results.json`；优化后的照片与远景取 `candidate/controlled/results.json`，近景取 `candidate/verified-near/results.json`，汇总为 `comparison.json`。

## 内存与 CPU 诊断

遍历 21 张照片后，共享高清/缩略图纹理持有量从 **44.55 MiB 降至 6.96 MiB（-84.4%）**。当前照片仍为最长边 1440px。

| profile 场景（GC 后快照） | 基线 PSS / MiB | 优化后 PSS / MiB | 差值 / MiB |
| --- | ---: | ---: | ---: |
| 照片已浏览完 | 537.87 | 438.43 | -99.44 |
| 照片页下压着地球近景，已拖动 | 660.80 | 590.76 | -70.04 |
| 从近景回到地球远景 | 626.90 | 543.27 | -83.63 |
| 第 5 轮退出到入口 | 417.20 | 431.27 | +14.06 |

从近景回到远景后，基线仍持有 104 块地图网格和 117 个地图纹理对象；优化版两者均归零，压缩图缓存保留。上表地球页面还包含背后的照片页，不能把全部 PSS 下降单独归因于地球。

五轮退出后的页面状态、Scene、地图纹理和共享纹理对象均为 0。优化版第 5 轮退出 PSS 比基线高约 14 MiB，后几轮基本稳定；该项未改善，不宣称所有进程内存都已回收，也不将未细分驻留量当作已定位泄漏。

Dart 主 isolate 的加载阶段 CPU 采样中，`pow` 占比从 36.25% 降到 1.16%，`generateMipChain` 从 12.91% 降到 0.31%。这些是采样栈的包含比例，不能相加；计算被转移到后台，不等于总 CPU 消耗消失。

详细证据：`baseline/profile-final/` 和 `candidate/profile-final/`，包括每轮分配快照、CPU 样本、VM 内存、缓存计数和 PSS。

## Perfetto 交叉诊断

重新采集的轻量 trace 完整覆盖约 22 秒，无记录到的解析错误或数据丢失。按本应用 PID 汇总调度 CPU 时间（单次诊断窗，不混入三轮中位数）：

| 场景 / 线程 | 基线 CPU 时间 / ms | 优化后 / ms | 解释 |
| --- | ---: | ---: | --- |
| 照片滑动 / Raster | 10587.21 | 5856.74 | 模糊分组合并后线程开销下降 |
| 照片滑动 / 主线程 | 8227.70 | 8550.90 | 小幅增加，与 FrameTiming 的 UI 变化一致 |
| 地球初始化拖动 / 主线程 | 8149.65 | 6910.04 | 主线程工作减少 |
| 地球初始化拖动 / DartWorker | 1252.70 | 3083.61 | 后台计算增加，不据此宣称总 CPU 或能耗下降 |

该设备的 FrameTimeline 只出现 SurfaceFlinger 和 SystemUI，未出现本应用的 SurfaceView 轨道，因此不报告应用实际 FPS 或最终呈现卡顿率。证据为两组 `diagnostics/*.perfetto-trace` 与 `.sql.txt`。

## 画质及边界

照片渲染仍为 0.75，地球仍为 1.0；地图最高 z18。1080×2378 截图排除状态栏后，地球远景逐像素一致；回忆空间实际照片区域平均 RGB 绝对差约 0.000007/255。玻璃控件和近景网格的整幅差异很小，已人工检查画面；没有以自评分代替验收。

一轮近景起始相机被移动，原始图片保留且该轮排除，近景已在只读投屏下重测。全部排除记录见 `capture-exclusions.json`。最初较重的 gfx/view/WM trace 出现缓冲区覆盖及厂商 systrace 解析错误，不据此宣称应用 FPS 或卡顿率。FrameTimeline 与 Flutter UI/Raster 耗时是不同口径，参见 [Perfetto 官方说明](https://perfetto.dev/docs/data-sources/frametimeline)。

异步贴图适配层集中复用了 flutter_scene 0.23.0 尚未从主入口导出的实现，依赖已固定为该版本；升级时需复验该适配层。未测能耗和长时间温升，不把 UI 工作移到后台等同于总 CPU 或耗电下降。

原始数据位于 `/tmp/flutter_3d_gallery_perf2_20260922/`，包括基线/优化 APK、源码快照、FrameTiming、PSS、Dart CPU 与分配样本、截图和 Perfetto trace。未提交、未推送。

## 复测与交付

```sh
offical
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64 -t tool/frame_probe.dart
python3 tool/run_perf_scenarios.py --serial <当前设备> --apk <探针APK> \
  --output <结果目录> --scenes memory_swipe,memory_buttons,globe,near,near_loading
# profile_probe.dart + Dart MCP/VM service 用于 CPU 和生命周期诊断。
flutter build apk --profile --target-platform android-arm64 -t tool/profile_probe.dart
python3 tool/profile_memory.py --serial <当前设备> --vm-info <VM连接信息JSON> --output <结果目录>
# 正式包使用普通入口。
flutter build apk --release --target-platform android-arm64 -t lib/main.dart
```

VM 信息 JSON 包含本次连接的 `appUri`（HTTP 地址）和 `isolateId`；必须重新发现当前连接。Perfetto 配置使用本轮 `trace-light.pbtxt`，通过设备内管道送入 perfetto，避免云机 ADB 的 stdin EOF 和配置文件读取限制。

正式 APK：`flutter_3d_demo/build/app/outputs/flutter-apk/app-release.apk`，153,133,693 字节，SHA-256 `4f18e1cde25ce4a7047c8f67113e1db77abf69b3f2ada22b45ab10429dfd9354`。已安装到当前 IRMA OPPO，设备上 APK 哈希一致，正式包不含 `GALLERY_FRAME` 探针标记。已恢复 min_refresh_rate=null、peak_refresh_rate=120.0 和可交互 scrcpy；USB 设备本轮未连接。
