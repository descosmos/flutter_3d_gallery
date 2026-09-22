import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_scene/scene.dart' as fs;

// GPU 用例需显式开启真实渲染后端，普通逻辑测试不会伪造 GPU 画面。
const runGpuTests = bool.fromEnvironment('RUN_GPU_TESTS');

Future<void> pumpGpuPage(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: page));
  });
  await waitForGpu(tester);
}

Future<void> waitForGpu(WidgetTester tester) async {
  for (int i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    if (fs.Scene.isReadyToRender && find.byType(fs.SceneView).evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 32));
      return;
    }
    final error = tester.takeException();
    if (error != null) throw error;
  }
  fail('GPU 场景未在 10 秒内就绪');
}
