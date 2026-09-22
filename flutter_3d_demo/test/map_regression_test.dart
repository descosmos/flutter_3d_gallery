import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_3d_demo/gpu/globe_page.dart';
import 'package:flutter_3d_demo/gpu/terrain_page.dart';
import 'package:flutter_3d_demo/story/photo_geo.dart';
import 'package:flutter_3d_demo/story/story_models.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'gpu_test_support.dart';
import 'photo_interactions_test.dart' show descendants, advance;

Future<void> waitUntil(WidgetTester tester, bool Function() condition) async {
  for (int i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (condition()) return;
    final error = tester.takeException();
    if (error != null) throw error;
  }
  fail('地图未在 30 秒内达到验收条件');
}

void main() {
  testWidgets('地球近看加载真实高清瓦片，轻微拖动不丢旗子，捏合抬指不跳动', (tester) async {
    const center = GeoPoint(44.6, 80.8);
    await pumpGpuPage(
      tester,
      GpuGlobePage(
        focus: center,
        story: demoStory,
        initialDistance: 2.012,
        photos: [MapEntry(photoGeo.keys.first, center)],
      ),
    );
    fs.SceneView view() =>
        tester.widget<fs.SceneView>(find.byType(fs.SceneView));
    fs.PerspectiveCamera camera() =>
        view().cameraBuilder!(Duration.zero) as fs.PerspectiveCamera;
    final scene = view().scene!,
        size = tester.getSize(find.byType(fs.SceneView));
    await waitUntil(
      tester,
      () =>
          descendants(scene.root).any((n) => n.name.startsWith('globe-tile:')),
    );
    final tiles = descendants(scene.root)
        .where((n) => n.name.startsWith('globe-tile:'))
        .toList();
    expect(tiles.length, greaterThan(4));
    expect(
      int.parse(tiles.first.name.split(':')[1].split('/')[0]),
      greaterThanOrEqualTo(13),
    );
    expect(
      tiles.every(
        (n) =>
            (n.mesh!.primitives.single.material as fs.UnlitMaterial)
                .baseColorTexture !=
            null,
      ),
      isTrue,
    );
    final flag = descendants(scene.root)
        .firstWhere((n) => n.name.startsWith('flag:'));
    final before = camera().worldToScreen(
      flag.globalTransform.getTranslation(),
      size,
    )!;
    final drag = await tester.startGesture(size.center(Offset.zero));
    await drag.moveBy(const Offset(22, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await drag.moveBy(const Offset(14, 5));
    await tester.pump(const Duration(milliseconds: 16));
    await drag.up();
    await advance(tester, frames: 5);
    final after = camera().worldToScreen(
      flag.globalTransform.getTranslation(),
      size,
    )!;
    expect((after - before).distance, lessThan(45));
    expect((Offset.zero & size).contains(after), isTrue);
    expect(flag.parent!.visible, isTrue);
    final startAltitude = camera().position.length - 2;
    final a = await tester.startGesture(
      size.center(Offset.zero) - const Offset(60, 0),
      pointer: 1,
    );
    final b = await tester.startGesture(
      size.center(Offset.zero) + const Offset(60, 0),
      pointer: 2,
    );
    for (int i = 0; i < 8; i++) {
      await a.moveBy(const Offset(-4, 0));
      await b.moveBy(const Offset(4, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      camera().position.length - 2,
      inInclusiveRange(startAltitude * .5, startAltitude * .9),
    );
    await a.up();
    await tester.pump(const Duration(milliseconds: 16));
    final heldPosition = camera().position.clone();
    await b.moveBy(const Offset(4, 3));
    await tester.pump(const Duration(milliseconds: 16));
    expect((camera().position - heldPosition).length, lessThan(.000001));
    await b.up();
    await tester.tap(find.byTooltip('回到旅行区域'));
    await waitUntil(
      tester,
      () =>
          !descendants(scene.root).any((n) => n.name.startsWith('globe-map:')),
    );
    expect(camera().position.length, closeTo(12, .001));
    for (int attempt = 0; attempt < 3; attempt++) {
      final left = await tester.startGesture(
        size.center(Offset.zero) - const Offset(40, 0),
        pointer: 11,
      );
      final right = await tester.startGesture(
        size.center(Offset.zero) + const Offset(40, 0),
        pointer: 12,
      );
      for (int step = 0; step < 10; step++) {
        await left.moveBy(const Offset(-8, 0));
        await right.moveBy(const Offset(8, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await left.up();
      await right.up();
      await advance(tester, frames: 3);
    }
    await waitUntil(
      tester,
      () =>
          descendants(scene.root).any((n) => n.name.startsWith('globe-tile:')),
    );
    debugPrint(
      'MAP_REGRESSION globe tileLevel=${tiles.first.name} dragPixels=${(after - before).distance}',
    );
  }, skip: !runGpuTests);

  testWidgets('地形缩小范围与低角度拖动后，每个旗杆都落在实际地形三角面上', (tester) async {
    const center = GeoPoint(44.6, 80.8);
    final points = [
      center,
      const GeoPoint(44.6, 81.12),
      const GeoPoint(44.42, 80.8),
      const GeoPoint(44.79, 80.48),
    ];
    final assets = photoGeo.keys.take(points.length).toList();
    await pumpGpuPage(
      tester,
      GpuTerrainPage(
        focus: center,
        story: demoStory,
        initialDistance: 34,
        initialPitch: .4,
        photos: [
          for (int i = 0; i < points.length; i++)
            MapEntry(assets[i], points[i]),
        ],
      ),
    );
    fs.SceneView view() =>
        tester.widget<fs.SceneView>(find.byType(fs.SceneView));
    fs.PerspectiveCamera camera() =>
        view().cameraBuilder!(Duration.zero) as fs.PerspectiveCamera;
    final scene = view().scene!,
        size = tester.getSize(find.byType(fs.SceneView));
    void checkGround() {
      final feet = descendants(scene.root)
          .where((n) => n.name.startsWith('anchor:'))
          .toList();
      expect(feet.length, points.length);
      for (final foot in feet) {
        final p = foot.globalTransform.getTranslation();
        final ground = scene.raycast(
          vm.Ray.originDirection(
            p + vm.Vector3(0, 10, 0),
            vm.Vector3(0, -1, 0),
          ),
          where: (n) => n.name.startsWith('terrain-tile:'),
        );
        expect(ground, isNotNull, reason: foot.name);
        expect(
          (p.y - ground!.worldPoint.y).abs(),
          lessThan(.002),
          reason: foot.name,
        );
      }
      expect(
        descendants(scene.root)
            .where((n) => n.name.startsWith('terrain-tile:'))
            .length,
        greaterThan(9),
      );
    }

    camera();
    checkGround();
    final a = await tester.startGesture(
      size.center(Offset.zero) - const Offset(80, 0),
      pointer: 1,
    );
    final b = await tester.startGesture(
      size.center(Offset.zero) + const Offset(80, 0),
      pointer: 2,
    );
    for (int i = 0; i < 16; i++) {
      await a.moveBy(const Offset(3, 0));
      await b.moveBy(const Offset(-3, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await advance(tester, frames: 30);
    expect((camera().position - camera().target).length, greaterThan(40));
    checkGround();
    final drag = await tester.startGesture(size.center(Offset.zero));
    for (int i = 0; i < 8; i++) {
      await drag.moveBy(const Offset(4, -3));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await advance(tester, frames: 25);
    checkGround();
    debugPrint(
      'MAP_REGRESSION terrain groundedFlags=${points.length} distance=${(camera().position - camera().target).length}',
    );
  }, skip: !runGpuTests);
}
