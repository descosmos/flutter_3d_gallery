import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_3d_demo/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory library;
  setUp(() async {
    library = await Directory.systemTemp.createTemp('travel_home_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => library.path,
        );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await library.delete(recursive: true);
  });
  testWidgets('应用启动进入本机选图首页，原首页仍可从示例模版打开', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const Flutter3DDemoApp());
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();

    expect(find.text('我的旅行照片'), findsOneWidget);
    expect(find.text('选择本机照片'), findsOneWidget);
    expect(find.text('回忆空间'), findsOneWidget);
    expect(find.text('3D 照片地球'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('open-local-space')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('open-local-globe')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('示例模版'));
    await tester.runAsync(() async {
      await tester.pumpAndSettle();
    });
    expect(find.text('新疆环线'), findsOneWidget);
    expect(find.text('进入 3D 回忆空间'), findsOneWidget);
  });
}
