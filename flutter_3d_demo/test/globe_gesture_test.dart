// 3D 地球仪手势黑盒测试：拖动旋转、双击打开地点照片空间、双指捏合缩放。
// 只用公开 widget 类型与屏幕坐标断言，不依赖私有 state。
// 注意：GlobePhotoMap 内部有常转 Ticker（惯性/自转），全程用 0ms/定时 pump，
// 不用 pumpAndSettle；地球纹理（rootBundle + instantiateImageCodec）与
// 缩略图的真实解码需要 runAsync 窗口；测试环境缺 CJK 字形，不断言文本内容。
import 'package:flutter/gestures.dart' show kDoubleTapMinTime;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_3d_demo/pages/location_photo_space.dart';
import 'package:flutter_3d_demo/pages/photo_map_globe.dart';
import 'package:flutter_3d_demo/pages/photo_map_shared.dart';
import 'package:flutter_3d_demo/story/photo_geo.dart';

// 两个相距较远的拍摄地（屏幕上 ~95px，不会聚合成组），用于拖动/缩放。
const _thumbA = 'assets/thumbs/IMG_20240503_093552.jpg';
const _thumbB = 'assets/thumbs/IMG_20240504_121047.jpg';
// 双击/长按打开地点照片空间用的第三处拍摄地（只用缩略图）。
const _thumbC = 'assets/thumbs/IMG_20240503_180134.jpg';

const _markerA = PhotoMapMarker(
    storyIndex: 0, thumbAsset: _thumbA, point: GeoPoint(38.273707, 99.882639));
const _markerB = PhotoMapMarker(
    storyIndex: 1, thumbAsset: _thumbB, point: GeoPoint(45.604245, 87.421024));
const _markerC = PhotoMapMarker(
    storyIndex: 0, thumbAsset: _thumbC, point: GeoPoint(43.898658, 87.642832));

/// 按缩略图资产路径定位地标卡片里的 Image。
/// 卡片本体是私有的 _LandmarkCard，公开层面用 Image 的 AssetImage 路径最稳定
/// （两个 marker 用不同 thumbAsset，互不歧义）。
/// 卡片以 cacheWidth 降采样解码（省纹理内存），provider 被 ResizeImage
/// 包装，先解包再比对 AssetImage。
Finder cardImage(String thumbAsset) => find.byWidgetPredicate((widget) {
      if (widget is! Image) return false;
      var provider = widget.image;
      if (provider is ResizeImage) provider = provider.imageProvider;
      return provider is AssetImage && provider.assetName == thumbAsset;
    });

/// pump 出地球仪并等纹理与图片真实解码。
/// 逻辑尺寸 800x1200：rPix 较大，300px 拖动（约 63°）后两个地标仍留在前半球。
Future<void> pumpGlobe(WidgetTester tester, List<PhotoMapMarker> markers,
    {int focusIndex = 0}) async {
  tester.view.physicalSize = const Size(1600, 2400);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GlobePhotoMap(
          markers: markers,
          focusIndex: focusIndex,
          onSelectStory: (_) {},
          onClose: () {},
        ),
      ),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 800));
  });
  await tester.pump();
}

/// 本 SDK 的 WidgetTester 已移除 doubleTap：手动发两次间隔 kDoubleTapMinTime
/// 的点按，走 DoubleTapGestureRecognizer 的正常识别路径（< kDoubleTapTimeout）。
/// 结尾再 pump 一个 kDoubleTapMinTime：DoubleTapGestureRecognizer 为每次点按
/// 创建的 _TapTracker 倒计时 Timer（40ms）必须到期，否则测试结束时报
/// "A Timer is still pending"。
Future<void> doubleTapAt(WidgetTester tester, Offset location) async {
  await tester.tapAt(location);
  await tester.pump(kDoubleTapMinTime);
  await tester.tapAt(location);
  await tester.pump(kDoubleTapMinTime);
}

/// 以球心（宽 1/2、高 0.46 处）为焦点双指捏合：小步交替移动模拟真实
/// 捏合（焦点基本锚在球心；单次大跨步会让焦点跳变把内容甩偏）。
/// open=true 张开累计 scale 3.8 → zoom 越过过渡带 3.6 进入地图模式；
/// open=false 反向缩回 zoom≈1.4 回到球体。
/// [steps] 可覆盖步数做小幅缩放（每步双指间距 ±20px，10 步≈scale 2.0）。
Future<void> pinchZoom(WidgetTester tester, {required bool open, int? steps}) async {
  final size = tester.getSize(find.byType(GlobePhotoMap));
  final mc = Offset(size.width / 2, size.height * 0.46);
  final apart = open ? 100.0 : 280.0;
  final step = open ? 10.0 : -10.0;
  final finger1 = await tester.startGesture(mc - Offset(apart, 0));
  final finger2 = await tester.startGesture(mc + Offset(apart, 0));
  for (var i = 0; i < (steps ?? (open ? 28 : 18)); i++) {
    await finger1.moveBy(Offset(-step, 0));
    await finger2.moveBy(Offset(step, 0));
  }
  await finger1.up();
  await finger2.up();
  await tester.pump();
}

void main() {
  testWidgets('全景：photoGeo 全量并入后出现大数字徽标聚合组', (tester) async {
    await pumpGlobe(tester, const [_markerA, _markerB]);
    // 徽标是纯数字 Text（聚合组成员计数）；页面其余文本均非纯数字
    final badges = find.byWidgetPredicate(
        (w) => w is Text && int.tryParse(w.data ?? '') != null);
    final counts = tester
        .widgetList<Text>(badges)
        .map((t) => int.parse(t.data!))
        .toList();
    // ignore: avoid_print
    print('全景聚合徽标计数: $counts');
    expect(counts, isNotEmpty, reason: '全景应出现聚合组徽标');
    final maxCount = counts.reduce((a, b) => a > b ? a : b);
    expect(maxCount, greaterThan(400),
        reason: '632 张照片并入后全景应出现数百张的大聚合组');
    final total = counts.fold<int>(0, (a, b) => a + b);
    expect(total, greaterThan(600),
        reason: '全景可见聚合成员总数应覆盖几乎全部 632 张照片');
  });

  testWidgets('拖动旋转：地标卡片随地球旋转发生明显位移', (tester) async {
    await pumpGlobe(tester, const [_markerA, _markerB]);
    final cardA = cardImage(_thumbA);
    final cardB = cardImage(_thumbB);
    expect(cardA, findsOneWidget);
    expect(cardB, findsOneWidget);
    final beforeA = tester.getCenter(cardA);
    final beforeB = tester.getCenter(cardB);

    // 水平拖动 300px。drag 只派发手势事件不走帧，随后的 0ms pump 只触发重建
    // （Ticker dt=0，惯性角速度不生效），卡片位移全部来自拖动本身。
    await tester.drag(find.byType(GlobePhotoMap), const Offset(-300, 0));
    await tester.pump();

    // 旋转后两地标仍在前半球、未聚合成组
    expect(cardA, findsOneWidget);
    expect(cardB, findsOneWidget);
    final movedA = (tester.getCenter(cardA) - beforeA).distance;
    final movedB = (tester.getCenter(cardB) - beforeB).distance;
    expect(movedA, greaterThan(100), reason: '焦点地标卡片应随旋转明显移动');
    expect(movedB, greaterThan(100), reason: '另一地标卡片应随旋转明显移动');
  });

  testWidgets('双击地标卡片打开地点照片空间，点空白关闭', (tester) async {
    await pumpGlobe(tester, const [_markerC]);
    final card = cardImage(_thumbC);
    expect(card, findsOneWidget);
    expect(find.byType(LocationPhotoSpace), findsNothing);

    await doubleTapAt(tester, tester.getCenter(card));
    await tester.pump();
    expect(find.byType(LocationPhotoSpace), findsOneWidget);

    // 底部提示区是 IgnorePointer，点空白即关闭
    await tester.tapAt(const Offset(400, 1150));
    await tester.pump();
    expect(find.byType(LocationPhotoSpace), findsNothing);
  });

  testWidgets('双指张开捏合：地标卡片间屏幕距离变大', (tester) async {
    await pumpGlobe(tester, const [_markerA, _markerB]);
    final cardA = cardImage(_thumbA);
    final cardB = cardImage(_thumbB);
    expect(cardA, findsOneWidget);
    expect(cardB, findsOneWidget);
    final beforeDist =
        (tester.getCenter(cardA) - tester.getCenter(cardB)).distance;

    // 两指从相距 200px 移动到相距 400px（以屏幕中部为焦点对称张开）。
    final center = tester.getCenter(find.byType(GlobePhotoMap));
    final finger1 = await tester.startGesture(center - const Offset(100, 0));
    final finger2 = await tester.startGesture(center + const Offset(100, 0));
    await finger1.moveBy(const Offset(-100, 0));
    await finger2.moveBy(const Offset(100, 0));
    await finger1.up();
    await finger2.up();
    await tester.pump();

    // 缩放只把地标牌在屏幕上摊开（牌面尺寸不随 zoom 变化），
    // 因此断言两张卡片中心的屏幕距离明显变大。
    // 注意：全量地标并入后两卡各自与附近照片聚合成组、锚点为组成员质心，
    // 缩放时组拆分使锚点回移，距离比略低于纯几何缩放（约 1.37），阈值取 1.3。
    expect(cardA, findsOneWidget);
    expect(cardB, findsOneWidget);
    final afterDist =
        (tester.getCenter(cardA) - tester.getCenter(cardB)).distance;
    expect(afterDist, greaterThan(beforeDist * 1.3),
        reason: '双指张开后两张地标卡片应明显散开');
  });

  testWidgets('双指连续放大越过阈值：进入并退出街道级地图模式', (tester) async {
    await pumpGlobe(tester, const [_markerA, _markerB]);
    // 球体模式没有地图提示
    expect(find.byKey(const ValueKey('mapModeHint')), findsNothing);

    // 张开累计 scale 3.8 → zoom 越过过渡带 3.6
    await pinchZoom(tester, open: true);
    // 黑盒特征：地图模式提示与街道级标题出现（测试环境瓦片必失败，数据源
    // 会自动兜底切换，标题后缀不确定，只断言稳定前缀）
    expect(find.byKey(const ValueKey('mapModeHint')), findsOneWidget);
    expect(find.textContaining('街道级地图'), findsOneWidget);
    expect(find.textContaining('拖动浏览'), findsNothing);

    // 反向捏合缩回 zoom≈1.4：退出地图模式回到球体
    await pinchZoom(tester, open: false);
    expect(find.byKey(const ValueKey('mapModeHint')), findsNothing);
    expect(find.textContaining('拖动浏览'), findsOneWidget);
    expect(find.textContaining('拖动旋转地球仪'), findsOneWidget);
  });

  testWidgets('地图模式：连续缩放后同一地点组徽标计数不变（网格聚合不拆分）',
      (tester) async {
    await pumpGlobe(tester, const [_markerA, _markerB]);
    await pinchZoom(tester, open: true); // zoom≈3.8，越过混合带进入地图模式
    expect(find.byKey(const ValueKey('mapModeHint')), findsOneWidget);

    // markerA 是当前焦点，是其所在地理网格组的代表卡（rep 优先级
    // 焦点>故事>普通）。卡片右上徽标距卡中心 ~35px；markerA 组地处空旷
    // 区域（相邻组数百 px 外），卡中心 60px 内最近的数字徽标必是自己的。
    int badgeOf(String thumb) {
      final c = tester.getCenter(cardImage(thumb));
      var bestD = double.infinity;
      var best = -1;
      final badges = find.byWidgetPredicate(
          (w) => w is Text && int.tryParse(w.data ?? '') != null);
      for (final b in tester.widgetList<Text>(badges)) {
        final d = (tester.getCenter(find.byWidget(b)) - c).distance;
        if (d < bestD) {
          bestD = d;
          best = int.parse(b.data!);
        }
      }
      expect(bestD, lessThan(60), reason: '卡片 60px 内应有自己的数字徽标');
      return best;
    }

    // 点按 markerA 卡飞向该地点组（飞行动画精确以组质心为中心，直达
    // 街道级 zoom 8.0）。注意：合成捏合的双指交替移动有系统性焦点漂移，
    // 不能用大跨度捏合导航；点按飞行是确定性的。tap 需等双击超时 300ms
    // 才触发 onTap，再推进 950ms 飞行动画。
    expect(cardImage(_thumbA), findsOneWidget);
    await tester.tapAt(tester.getCenter(cardImage(_thumbA)));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 1100));
    expect(cardImage(_thumbA), findsOneWidget);
    final street = badgeOf(_thumbA);
    expect(street, greaterThan(1), reason: 'markerA 所在网格组有 2 张照片，应带徽标');

    // 第一次缩放：捏合缩小（zoom 8.0 → ≈5.1）。地图模式焦点锚定是精确
    // 单应反解，无漂移，markerA 组保持在屏幕中心。
    await pinchZoom(tester, open: false, steps: 5);
    expect(cardImage(_thumbA), findsOneWidget);
    final zoomedOut = badgeOf(_thumbA);

    // 第二次缩放：捏合放大（zoom ≈5.1 → 8.0 上限）
    await pinchZoom(tester, open: true, steps: 7);
    expect(cardImage(_thumbA), findsOneWidget);
    final zoomedIn = badgeOf(_thumbA);

    // ignore: avoid_print
    print('地图模式缩放后 markerA 组徽标: $street -> $zoomedOut -> $zoomedIn');
    // 旧屏幕距离聚合在缩放后会拆分/合并（徽标变小、变大或单卡无徽标）；
    // 地理网格聚合组只随 markers 重建，缩小不合并、放大不拆分，徽标稳定。
    expect(zoomedOut, street, reason: '地理网格聚合：缩小不合并，徽标计数稳定');
    expect(zoomedIn, street, reason: '地理网格聚合：放大不拆分，徽标计数稳定');
  });

  testWidgets('地图模式 2D/3D 切换：按钮标签翻转，动画后地图仍渲染',
      (tester) async {
    await pumpGlobe(tester, const [_markerA, _markerB]);
    // 球体模式无 2D/3D 按钮
    expect(find.byKey(const ValueKey('tiltToggle')), findsNothing);

    await pinchZoom(tester, open: true);
    expect(find.byKey(const ValueKey('mapModeHint')), findsOneWidget);
    final tiltBtn = find.byKey(const ValueKey('tiltToggle'));
    expect(tiltBtn, findsOneWidget);
    // 默认 3D 倾斜视角，按钮标签显示可切到的目标模式 "2D"
    expect(find.text('2D'), findsOneWidget);
    expect(find.text('3D'), findsNothing);

    // 切到 2D：标签立即翻转为 "3D"，推进 600ms 俯仰动画后地图仍渲染
    await tester.tap(tiltBtn);
    await tester.pump();
    expect(find.text('3D'), findsOneWidget);
    expect(find.text('2D'), findsNothing);
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(const ValueKey('mapModeHint')), findsOneWidget);
    expect(find.textContaining('街道级地图'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);

    // 切回 3D 倾斜视角
    await tester.tap(tiltBtn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('2D'), findsOneWidget);
    expect(find.text('3D'), findsNothing);
    expect(find.byKey(const ValueKey('mapModeHint')), findsOneWidget);
  });

  testWidgets('地图模式 tilt>15° 启用三维地形 mesh（状态特征）', (tester) async {
    await pumpGlobe(tester, const [_markerA, _markerB]);
    // 球体模式无地形
    expect(find.byKey(const ValueKey('terrainMeshOn')), findsNothing);

    await pinchZoom(tester, open: true);
    expect(find.byKey(const ValueKey('mapModeHint')), findsOneWidget);
    // 默认 55° 倾斜且 DEM（assets/terrain.bin）真实加载完成 → 地形路径启用
    expect(find.byKey(const ValueKey('terrainMeshOn')), findsOneWidget);

    // 切 2D（点按节奏与既有 2D/3D 用例一致）：600ms 俯仰动画到 0° 后
    // 地形路径停用，地图仍渲染不崩
    final tiltBtn = find.byKey(const ValueKey('tiltToggle'));
    await tester.tap(tiltBtn);
    await tester.pump();
    expect(find.text('3D'), findsOneWidget); // 标签翻转 = 切换已注册
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(const ValueKey('terrainMeshOn')), findsNothing);
    expect(find.byKey(const ValueKey('mapModeHint')), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);

    // 切回 3D 倾斜 → 地形路径恢复
    await tester.tap(tiltBtn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(const ValueKey('terrainMeshOn')), findsOneWidget);
  });
}
