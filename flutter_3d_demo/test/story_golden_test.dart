import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_3d_demo/pages/entry_page.dart';
import 'package:flutter_3d_demo/pages/generating_page.dart';
import 'package:flutter_3d_demo/pages/interactive_story_page.dart';
import 'package:flutter_3d_demo/player/story_player_page.dart';
import 'package:flutter_3d_demo/story/story_models.dart';

/// 关键页面的截图验证：入口页、生成页、播放器各章节代表时刻。
/// 截图输出到 test/shots/ 目录，可直接查看。
/// 运行 `flutter test test/story_golden_test.dart` 生成。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> snap(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final element = tester.element(find.byType(MaterialApp));
      final ui.Image image = await captureImage(element);
      final bytes =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File('test/shots/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
    });
  }

  Future<void> pumpScenario(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(810, 1710);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: child));
      // 等待图片资源真实解码
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pump();
  }

  testWidgets('入口页', (tester) async {
    await pumpScenario(tester, const MemoryEntryPage());
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.pump();
    await snap(tester, 'entry');
  });

  testWidgets('生成页 中段', (tester) async {
    await pumpScenario(tester, GeneratingPage(story: demoStory));
    // 推进到约 55%（repeat 动画不能用 pumpAndSettle）
    for (int i = 0; i < 37; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await snap(tester, 'generating');
  });

  final playerMoments = <String, double>{
    'opening': 2.5, // 开场全景推进 + 空间字幕
    'journey': 13.0, // 抵达：视差平移
    'lakeside': 26.0, // 湖畔：焦点转移/推拉
    'people': 40.0, // 人物：微环绕（互动镜头）
    'snow': 59.0, // 雪山：空间卡片环绕
    'night': 74.0, // 尾声：静态+粒子
    'converge': 84.5, // 片尾：卡片收拢成封面
    'end': 89.5, // 播完：结束浮层
  };

  for (final entry in playerMoments.entries) {
    testWidgets('播放器 ${entry.key} (t=${entry.value}s)', (tester) async {
      await pumpScenario(
          tester, StoryPlayerPage(story: demoStory, startAt: entry.value));
      // 推进少量帧让转场/字幕动画稳定，且不至于偏离目标时刻太多
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      await snap(tester, 'player_${entry.key}');
    });
  }

  testWidgets('互动空间 默认', (tester) async {
    await pumpScenario(tester, InteractiveStoryPage(story: demoStory));
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await snap(tester, 'interactive');
  });

  testWidgets('互动空间 环视拖动后', (tester) async {
    await pumpScenario(tester, InteractiveStoryPage(story: demoStory));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.drag(
        find.byType(InteractiveStoryPage), const Offset(-260, 0));
    await tester.pump(const Duration(milliseconds: 120));
    await snap(tester, 'interactive_drag');
  });

  testWidgets('互动空间 路线图', (tester) async {
    await pumpScenario(tester, InteractiveStoryPage(story: demoStory));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byIcon(Icons.map_outlined).first);
    // 先构建出地图与图片标记，再等真实解码，最后推进生长动画
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 800)));
    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 再等一次真实解码窗口（动画期间的泵是假时间）
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.pump();
    await snap(tester, 'interactive_map');
  });
}
