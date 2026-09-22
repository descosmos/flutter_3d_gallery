import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_3d_demo/pages/location_photo_space.dart';
import 'package:flutter_3d_demo/pages/photo_map_shared.dart';
import 'package:flutter_3d_demo/story/photo_geo.dart';

import 'gpu_test_support.dart';

void main() {
  testWidgets('地点照片在 GPU 场景中渲染，保留照片数与返回操作', (tester) async {
    var closed = false;
    await pumpGpuPage(
      tester,
      Scaffold(
        body: Stack(
          children: [
            LocationPhotoSpace(
              photos: const [
                PhotoMapMarker(
                  storyIndex: 0,
                  thumbAsset: 'assets/thumbs/IMG_20240503_093552.jpg',
                  point: GeoPoint(38.27, 99.88),
                ),
              ],
              placeName: '青海湖',
              onClose: () => closed = true,
            ),
          ],
        ),
      ),
    );
    expect(find.byType(fs.SceneView), findsOneWidget);
    expect(find.text('青海湖'), findsOneWidget);
    expect(find.text('第 1 / 1 张'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pump();
    expect(closed, isTrue);
  }, skip: !runGpuTests);
}
