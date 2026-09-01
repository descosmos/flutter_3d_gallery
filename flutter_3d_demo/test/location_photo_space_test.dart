// 地点照片 3D 浏览浮层测试：初始渲染、水平拖动切换焦点、点空白关闭、单张退化。
// 组件内有常转粒子 Ticker 与吸附/回弹动画，全程定时 pump，不用 pumpAndSettle；
// 缩略图真实解码需要 runAsync 窗口（先 pump 构建出 Image，再 runAsync 等待）；
// 测试环境缺 CJK 字形，但 find.text 匹配字符串数据，可正常断言。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_3d_demo/pages/location_photo_space.dart';
import 'package:flutter_3d_demo/pages/photo_map_shared.dart';
import 'package:flutter_3d_demo/player/spatial_photo.dart';
import 'package:flutter_3d_demo/story/photo_geo.dart';

// thumbs/ 下真实存在的缩略图（浮层只加载缩略图，不碰 photos/ 大图）
const _thumbA = 'assets/thumbs/IMG_20240503_093552.jpg';
const _thumbB = 'assets/thumbs/IMG_20240503_093559.jpg';
const _thumbC = 'assets/thumbs/IMG_20240503_095424.jpg';

const _markerA = PhotoMapMarker(
    storyIndex: 0, thumbAsset: _thumbA, point: GeoPoint(38.273707, 99.882639));
const _markerB = PhotoMapMarker(
    storyIndex: 1, thumbAsset: _thumbB, point: GeoPoint(38.273707, 99.882639));
const _markerC = PhotoMapMarker(
    storyIndex: 2, thumbAsset: _thumbC, point: GeoPoint(38.273707, 99.882639));
const _photos = [_markerA, _markerB, _markerC];

/// pump 出浮层并等缩略图真实解码。逻辑视图 800x1200@2.0。
Future<void> pumpSpace(
  WidgetTester tester, {
  List<PhotoMapMarker> photos = _photos,
  String placeName = '青海湖断崖',
  VoidCallback? onClose,
}) async {
  tester.view.physicalSize = const Size(1600, 2400);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          LocationPhotoSpace(
            photos: photos,
            placeName: placeName,
            onClose: onClose ?? () {},
          ),
        ]),
      ),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 800));
  });
  await tester.pump();
}

void main() {
  testWidgets('初始渲染：焦点卡、序号、地点名与照片数', (tester) async {
    await pumpSpace(tester);
    expect(find.byType(SpatialPhotoCard), findsOneWidget);
    expect(find.text('青海湖断崖'), findsOneWidget);
    expect(find.text('3 张照片'), findsOneWidget);
    expect(find.text('第 1 / 3 张'), findsOneWidget);
  });

  testWidgets('水平拖动环视后焦点切换', (tester) async {
    await pumpSpace(tester);
    expect(find.text('第 1 / 3 张'), findsOneWidget);

    // 从焦点卡下方的空白处起拖（从卡上起拖会命中视差手势而非环视）。
    // 注意必须分多小步移动：单个 moveBy 的 delta 会被拖动手势识别器当作
    // 跨过 slop 的事件吞掉，onHorizontalDragUpdate 一次也不会触发。
    final gesture = await tester.startGesture(const Offset(400, 900));
    for (int i = 0; i < 26; i++) {
      await gesture.moveBy(const Offset(-10, 0));
    }
    await gesture.up();
    // 吸附动画 420ms，分帧推进（常转粒子不能用 pumpAndSettle）
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('第 3 / 3 张'), findsOneWidget);
  });

  testWidgets('点空白触发 onClose，点焦点卡不关闭', (tester) async {
    var closed = 0;
    await pumpSpace(tester, onClose: () => closed++);

    // 焦点卡中心（800x1200 视图下在屏幕中部偏上）
    await tester.tapAt(const Offset(400, 550));
    await tester.pump();
    expect(closed, 0);

    // 卡片下方空白
    await tester.tapAt(const Offset(400, 900));
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('单张照片退化为居中大卡，点空白仍可关闭', (tester) async {
    var closed = 0;
    await pumpSpace(tester, photos: const [_markerA], onClose: () => closed++);
    expect(find.byType(SpatialPhotoCard), findsOneWidget);
    expect(find.text('第 1 / 1 张'), findsOneWidget);

    await tester.tapAt(const Offset(400, 900));
    await tester.pump();
    expect(closed, 1);
  });
}
