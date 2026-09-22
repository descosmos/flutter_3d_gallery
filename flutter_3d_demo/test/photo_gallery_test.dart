import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_3d_demo/gpu/photo_preview.dart';
import 'package:flutter_3d_demo/story/photo_geo.dart';

Finder currentPhotoViewer() => find.ancestor(
  of: find.byKey(const ValueKey('photo-preview-image')),
  matching: find.byType(InteractiveViewer),
);

Future<void> swipeAlbum(WidgetTester tester) async {
  final viewer = currentPhotoViewer();
  final gesture = await tester.startGesture(tester.getCenter(viewer));
  for (var i = 0; i < 20; i++) {
    await gesture.moveBy(const Offset(-14, 0));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await gesture.up();
  await tester.pumpAndSettle();
  final pages = tester.widget<PageView>(
    find.byKey(const ValueKey('photo-gallery-pages')),
  );
  final page = pages.controller!.page!;
  expect(
    page,
    closeTo(page.roundToDouble(), .001),
    reason: '抬指后照片必须完整停靠，不能卡在半页',
  );
}

Future<void> settleAlbum(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> pinchAlbum(WidgetTester tester, {required bool out}) async {
  final center = tester.getCenter(currentPhotoViewer());
  final start = out ? 30.0 : 90.0;
  final delta = out ? 60.0 : -72.0;
  final a = await tester.startGesture(center - Offset(start, 0), pointer: 10);
  final b = await tester.startGesture(center + Offset(start, 0), pointer: 11);
  await tester.pump();
  for (var i = 0; i < 10; i++) {
    await a.moveBy(Offset(-delta / 10, 0));
    await b.moveBy(Offset(delta / 10, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await a.up();
  await b.up();
  await tester.pumpAndSettle();
}

void main() {
  for (final touchSlop in <double?>[null, 8]) {
    testWidgets('悬浮相册翻页缩放和返回（触摸阈值 $touchSlop）', (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      if (touchSlop != null) {
        tester.view.gestureSettings = ui.GestureSettings(
          physicalTouchSlop: touchSlop,
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showPhotoGallery(context, photoGeo.keys.take(4).toList()),
                  child: const Text('打开地点相册'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开地点相册'));
      await settleAlbum(tester);
      expect(find.text('1 / 4'), findsOneWidget);
      final current = currentPhotoViewer();
      double scale() => tester
          .widget<InteractiveViewer>(current)
          .transformationController!
          .value
          .getMaxScaleOnAxis();
      await swipeAlbum(tester);
      expect(find.text('2 / 4'), findsOneWidget);
      await pinchAlbum(tester, out: true);
      expect(scale(), greaterThan(1.5));
      await tester.drag(current, const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(find.text('2 / 4'), findsOneWidget);
      await pinchAlbum(tester, out: false);
      expect(scale(), closeTo(1, .01));
      await swipeAlbum(tester);
      expect(find.text('3 / 4'), findsOneWidget);
      await tester.tap(find.byTooltip('上一张照片'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 4'), findsOneWidget);
      final center = tester.getCenter(current);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(scale(), closeTo(2.5, .01));
      await tester.tap(find.byTooltip('下一张照片'));
      await tester.pumpAndSettle();
      expect(find.text('3 / 4'), findsOneWidget);
      expect(scale(), closeTo(1, .01));
      await tester.tap(find.byKey(const ValueKey('photo-preview-close')));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoPreview), findsNothing);
      expect(find.text('打开地点相册'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
