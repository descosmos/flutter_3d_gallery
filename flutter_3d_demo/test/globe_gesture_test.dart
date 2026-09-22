import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_3d_demo/gpu/globe_page.dart';
import 'package:flutter_3d_demo/story/photo_geo.dart';
import 'package:flutter_3d_demo/story/story_models.dart';

import 'gpu_test_support.dart';

void main() {
  testWidgets('GPU 地球采用球面几何，射线命中前方球面，捏合移动相机', (tester) async {
    await pumpGpuPage(
      tester,
      GpuGlobePage(focus: const GeoPoint(0, 0), story: demoStory),
    );
    final view = tester.widget<fs.SceneView>(find.byType(fs.SceneView));
    final camera =
        (view.camera ?? view.cameraBuilder!(Duration.zero))
            as fs.PerspectiveCamera;
    final size = tester.getSize(find.byType(fs.SceneView));
    final hit = view.scene!.raycast(
      camera.screenPointToRay(size.center(Offset.zero), size),
    );
    expect(hit?.node.name, 'earth');
    final distance = camera.position.length;
    final c = tester.getCenter(find.byType(fs.SceneView));
    final a = await tester.startGesture(c - const Offset(50, 0), pointer: 1);
    final b = await tester.startGesture(c + const Offset(50, 0), pointer: 2);
    for (int i = 0; i < 10; i++) {
      await a.moveBy(const Offset(-4, 0));
      await b.moveBy(const Offset(4, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pump(const Duration(milliseconds: 16));
    expect(camera.position.length, lessThan(distance));
  }, skip: !runGpuTests);
}
