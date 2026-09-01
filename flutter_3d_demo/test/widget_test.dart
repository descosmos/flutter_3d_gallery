import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_3d_demo/main.dart';

void main() {
  testWidgets('应用启动进入回忆相册入口', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const Flutter3DDemoApp());
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();

    expect(find.text('新疆环线'), findsOneWidget);
    expect(find.text('进入 3D 回忆空间'), findsOneWidget);
  });
}
