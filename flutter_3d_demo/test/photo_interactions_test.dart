import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_3d_demo/gpu/globe_page.dart';
import 'package:flutter_3d_demo/gpu/photo_space_page.dart';
import 'package:flutter_3d_demo/gpu/photo_preview.dart';
import 'package:flutter_3d_demo/gpu/terrain_page.dart';
import 'package:flutter_3d_demo/pages/photo_map_shared.dart';
import 'package:flutter_3d_demo/story/photo_geo.dart';
import 'package:flutter_3d_demo/story/story_models.dart';

import 'gpu_test_support.dart';
import 'photo_gallery_test.dart' show currentPhotoViewer, swipeAlbum;

Iterable<fs.Node> descendants(fs.Node node) sync* {
  yield node;
  for (final child in node.children) {
    yield* descendants(child);
  }
}

List<fs.Node> flags(fs.Scene scene) =>
    descendants(scene.root)
        .where((n) => n.name.startsWith('flag:') && n.visible)
        .toList();

Future<void> doubleTap(WidgetTester tester, Offset position) async {
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 60));
}

Future<void> advance(WidgetTester tester, {int frames = 18}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
}

void main() {
  testWidgets('地点照片相机固定，拖动切图与捏合均不移动视角，双击可预览并返回', (tester) async {
    final photos = photoGeo.entries
        .take(5)
        .map(
          (e) =>
              PhotoMapMarker(storyIndex: -1, thumbAsset: e.key, point: e.value),
        )
        .toList();
    await pumpGpuPage(
      tester,
      GpuPhotoSpacePage(story: demoStory, photos: photos, placeName: '地点照片'),
    );
    final view = tester.widget<fs.SceneView>(find.byType(fs.SceneView));
    final camera = view.camera! as fs.PerspectiveCamera;
    final eye = camera.position.clone(), target = camera.target.clone();
    expect(find.text('绕到背面'), findsNothing);
    final start = tester.getCenter(find.byType(fs.SceneView));
    final gesture = await tester.startGesture(start);
    for (int i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(-10, 4));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await advance(tester);
    expect(camera.position, eye);
    expect(camera.target, target);
    expect(find.text('第 1 / 5 张'), findsNothing);
    final a = await tester.startGesture(
      start - const Offset(40, 0),
      pointer: 1,
    );
    final b = await tester.startGesture(
      start + const Offset(40, 0),
      pointer: 2,
    );
    await a.moveBy(const Offset(-50, -30));
    await b.moveBy(const Offset(50, 30));
    await a.up();
    await b.up();
    await advance(tester);
    expect(camera.position, eye);
    expect(camera.target, target);
    // 当前照片随环转到固定相机前方，使用实际网格中心定位。
    final ring = view.scene!.root.getChildByName('photo-ring')!;
    final candidates = ring.children.toList()
      ..sort(
        (a, b) => (a.globalTransform.getTranslation() - eye).length.compareTo(
          (b.globalTransform.getTranslation() - eye).length,
        ),
      );
    final position = camera.worldToScreen(
      candidates.first.globalTransform.getTranslation(),
      tester.getSize(find.byType(fs.SceneView)),
    )!;
    await doubleTap(tester, position);
    await advance(tester);
    expect(find.byType(PhotoPreview), findsOneWidget);
    expect(find.byKey(const ValueKey('photo-preview-image')), findsOneWidget);
    final image = tester.widget<Image>(
      find.byKey(const ValueKey('photo-preview-image')),
    );
    expect((image.image as AssetImage).assetName, startsWith('assets/photos/'));
    await tester.tap(find.byKey(const ValueKey('photo-preview-close')));
    await advance(tester);
    expect(find.byType(PhotoPreview), findsNothing);
    expect(camera.position, eye);
    expect(camera.target, target);
  }, skip: !runGpuTests);

  for (final terrain in [false, true]) {
    testWidgets('${terrain ? '地形' : '地球'}同地点照片保持折叠，双击悬浮浏览后恢复地图', (
      tester,
    ) async {
      const focus = GeoPoint(44.605, 80.805);
      final entries = photoGeo.entries
          .take(10)
          .map((e) => MapEntry(e.key, focus))
          .toList();
      await pumpGpuPage(
        tester,
        terrain
            ? GpuTerrainPage(focus: focus, story: demoStory, photos: entries)
            : GpuGlobePage(focus: focus, story: demoStory, photos: entries),
      );
      final view = tester.widget<fs.SceneView>(find.byType(fs.SceneView).first);
      fs.PerspectiveCamera camera() =>
          view.cameraBuilder!(Duration.zero) as fs.PerspectiveCamera;
      final scene = view.scene!;
      final eye = camera().position.clone(), target = camera().target.clone();
      expect(flags(scene).single.name, endsWith('count:10'));
      final position = camera().worldToScreen(
        flags(scene).single.globalTransform.getTranslation(),
        tester.getSize(find.byType(fs.SceneView)),
      )!;
      await doubleTap(tester, position);
      await advance(tester, frames: 25);
      expect(find.byType(PhotoPreview), findsOneWidget);
      expect(find.text('1 / 10'), findsOneWidget);
      final current = currentPhotoViewer();
      await swipeAlbum(tester);
      await advance(tester);
      expect(find.text('2 / 10'), findsOneWidget);
      await doubleTap(tester, tester.getCenter(current));
      await advance(tester);
      final zoom = tester
          .widget<InteractiveViewer>(current)
          .transformationController!;
      expect(zoom.value.getMaxScaleOnAxis(), closeTo(2.5, .01));
      await tester.drag(current, const Offset(-180, 0));
      await advance(tester);
      expect(find.text('2 / 10'), findsOneWidget);
      await tester.tap(find.byTooltip('还原图片'));
      await advance(tester);
      expect(zoom.value.getMaxScaleOnAxis(), closeTo(1, .01));
      await tester.tap(find.byKey(const ValueKey('photo-preview-close')));
      await advance(tester);
      expect(find.byType(PhotoPreview), findsNothing);
      expect(flags(scene).single.name, endsWith('count:10'));
      expect(camera().position, eye);
      expect(camera().target, target);
    }, skip: !runGpuTests);
  }

  testWidgets('地形不同地点仍可展开、预览及上一级恢复分组和相机', (tester) async {
    final entries = photoGeo.entries
        .take(4)
        .indexed
        .map(
          (e) => MapEntry(
            e.$2.key,
            GeoPoint(44.605 + (e.$1 ~/ 2) * .004, 80.805 + (e.$1 % 2) * .004),
          ),
        )
        .toList();
    await pumpGpuPage(
      tester,
      GpuTerrainPage(
        focus: const GeoPoint(44.607, 80.807),
        story: demoStory,
        photos: entries,
      ),
    );
    fs.SceneView view() =>
        tester.widget<fs.SceneView>(find.byType(fs.SceneView).first);
    fs.PerspectiveCamera camera() =>
        view().cameraBuilder!(Duration.zero) as fs.PerspectiveCamera;
    final scene = view().scene!;
    final eye = camera().position.clone(), target = camera().target.clone();
    expect(flags(scene).single.name, endsWith('count:4'));
    Future<void> openFirst() async {
      final node = flags(scene).first;
      final position = camera().worldToScreen(
        node.globalTransform.getTranslation(),
        tester.getSize(find.byType(fs.SceneView)),
      )!;
      await doubleTap(tester, position);
      await advance(tester, frames: 25);
    }

    await openFirst();
    expect(flags(scene).length, 4);
    expect(flags(scene).every((f) => f.name.endsWith('count:1')), isTrue);
    expect(
      (camera().position - camera().target).length,
      lessThan((eye - target).length),
    );
    await openFirst();
    expect(find.byType(PhotoPreview), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('photo-preview-close')));
    await advance(tester);
    await tester.tap(find.byKey(const ValueKey('terrain-cluster-up')));
    await advance(tester);
    expect(flags(scene).single.name, endsWith('count:4'));
    expect(camera().position, eye);
    expect(camera().target, target);
    await openFirst();
    await tester.tap(find.byTooltip('重置视角'));
    await advance(tester);
    expect(flags(scene).single.name, endsWith('count:4'));
    expect(find.byKey(const ValueKey('terrain-cluster-up')), findsNothing);
    expect(camera().position, eye);
    expect(camera().target, target);
  }, skip: !runGpuTests);
}
