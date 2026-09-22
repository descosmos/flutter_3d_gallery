import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_3d_demo/pages/interactive_story_page.dart';
import 'package:flutter_3d_demo/story/story_models.dart';
import 'package:flutter/material.dart';

import 'dart:math' as math;

import 'gpu_test_support.dart';

void main() {
  testWidgets('GPU 帧循环复用场景与网格，绕到背面改变真实相机位置', (tester) async {
    await pumpGpuPage(tester, InteractiveStoryPage(story: demoStory));
    final view = tester.widget<fs.SceneView>(find.byType(fs.SceneView));
    final scene = view.scene!;
    final camera = view.camera! as fs.PerspectiveCamera;
    final before = camera.position.clone();
    final node = scene.root.getChildByName('photo:0');
    expect(node, isNotNull);
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      tester.widget<fs.SceneView>(find.byType(fs.SceneView)).scene,
      same(scene),
    );
    expect(scene.root.getChildByName('photo:0'), same(node));
    await tester.tap(find.text('绕到背面'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(camera.position.z, lessThan(camera.target.z));
    expect(before.z, greaterThan(camera.target.z));
    await tester.tap(find.byTooltip('重置视角'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(camera.position.z, greaterThan(camera.target.z));
  }, skip: !runGpuTests);

  testWidgets('遍历照片后高清纹理保持有界，当前照片仍是高清', (tester) async {
    await pumpGpuPage(tester, InteractiveStoryPage(story: demoStory));
    final scene = tester.widget<fs.SceneView>(find.byType(fs.SceneView)).scene!;
    final count = demoStory.chapters
        .take(demoStory.chapters.length - 1)
        .fold<int>(0, (n, c) => n + c.shots.length);
    for (int i = 1; i < count; i++) {
      await tester.tap(find.byTooltip('下一张'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
    }
    Iterable<fs.Node> walk(fs.Node node) sync* {
      yield node;
      for (final child in node.children) {
        yield* walk(child);
      }
    }

    int currentResolution() {
      final current = scene.root.getChildByName('photo:${count - 1}')!;
      int pixels = 0;
      for (final node in walk(current)) {
        for (final primitive in node.mesh?.primitives ?? <fs.MeshPrimitive>[]) {
          final material = primitive.material;
          if (material is fs.UnlitMaterial) {
            final texture = material.baseColorTexture?.sampledTexture;
            if (texture != null) {
              pixels = math.max(
                pixels,
                math.max(texture.width, texture.height),
              );
            }
          }
        }
      }
      return pixels;
    }

    int cachedBytes() => fs
        .takeMemoryReport()
        .categories
        .singleWhere((c) => c.name == 'textures')
        .bytes!;
    for (
      int i = 0;
      i < 100 &&
          (currentResolution() < 1400 || cachedBytes() >= 12 * 1024 * 1024);
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 32));
    }
    expect(currentResolution(), greaterThanOrEqualTo(1400));
    final textures = fs.takeMemoryReport().categories.singleWhere(
      (c) => c.name == 'textures',
    );
    expect(textures.bytes!, lessThan(12 * 1024 * 1024));
    expect(find.byTooltip('下一张'), findsOneWidget);
    final next = tester.widget<IconButton>(
      find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '下一张'),
    );
    expect(next.onPressed, isNull);
  }, skip: !runGpuTests);
}
