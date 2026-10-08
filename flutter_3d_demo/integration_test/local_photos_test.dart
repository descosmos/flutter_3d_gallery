import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:integration_test/integration_test.dart';
import 'package:native_exif/native_exif.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter_3d_demo/gpu/globe_page.dart';
import 'package:flutter_3d_demo/gpu/photo_space_page.dart';
import 'package:flutter_3d_demo/gpu/photo_preview.dart';
import 'package:flutter_3d_demo/pages/travel_home_page.dart';
import 'package:flutter_3d_demo/photos/local_photo_library.dart';

import '../test/gpu_test_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真实 EXIF 导入、无 GPS 跳过、两个 GPU 场景、选择与重启恢复', (tester) async {
    final temporary = await (await getTemporaryDirectory()).createTemp(
      'travel_verify_',
    );
    final library = LocalPhotoLibrary(
      directory: Directory('${temporary.path}/library'),
    );
    addTearDown(() async {
      library.dispose();
      await temporary.delete(recursive: true);
    });
    final source = await rootBundle.load(
      'assets/photos/IMG_20240503_180134.jpg',
    );
    final paths = <String>[];
    for (int i = 0; i < 2; i++) {
      final file = await File('${temporary.path}/photo_$i.jpg').writeAsBytes(
        source.buffer.asUint8List(source.offsetInBytes, source.lengthInBytes),
      );
      final exif = await Exif.fromPath(file.path);
      await exif.writeAttributes({
        'GPSLatitude': '31.2304',
        'GPSLatitudeRef': 'N',
        'GPSLongitude': '121.4737',
        'GPSLongitudeRef': 'E',
        'DateTimeOriginal': '2026:09:${22 + i} 10:30:00',
        'Orientation': i == 0 ? '1' : '6',
      });
      await exif.close();
      paths.add(file.path);
    }
    final noGps = await File('${temporary.path}/no_gps.png').writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
      ),
    );
    await library.load();
    await library.importPaths([...paths, noGps.path, paths.first]);
    expect(library.error, isNull);
    expect(library.photos, hasLength(2));
    expect(library.notice, contains('跳过 1 张无位置信息'));
    expect(library.photos.first.point.lat, closeTo(31.2304, .00001));
    expect(library.photos.first.point.lng, closeTo(121.4737, .00001));
    final story = storyFromPhotos(library.selected);

    await pumpGpuPage(tester, GpuPhotoSpacePage(story: story));
    var view = tester.widget<fs.SceneView>(find.byType(fs.SceneView));
    final ring = view.scene!.root.getChildByName('photo-ring')!;
    expect(ring.children, hasLength(2));
    // Both dates, including the last chapter, remain browsable.
    expect(find.text('2026.09.23'), findsOneWidget);
    await tester.tap(find.byTooltip('下一张'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('第 2 张'), findsOneWidget);
    await tester.tap(find.byTooltip('3D 照片地图'));
    await waitForGpu(tester);
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump();
    expect(
      tester.widget<GpuGlobePage>(find.byType(GpuGlobePage)).photos,
      hasLength(2),
    );
    view = tester.widget<fs.SceneView>(find.byType(fs.SceneView).last);
    expect(
      view.scene!.root.getChildByName('landmarks')!.children,
      hasLength(1),
    );

    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        theme: ThemeData.dark(),
        home: TravelHomePage(library: library),
      ),
    );
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(find.text('已选 2 / 2 张'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-local-globe')));
    await waitForGpu(tester);
    expect(
      tester.widget<GpuGlobePage>(find.byType(GpuGlobePage)).photos,
      hasLength(2),
    );

    // Full-size file preview, including zoom, must use FileImage.
    final context = tester.element(find.byType(GpuGlobePage));
    showPhotoGallery(context, library.photos.map((p) => p.path).toList());
    for (int i = 0; i < 100 &&
        find.byKey(const ValueKey('photo-preview-image')).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    final image = tester.widget<Image>(
      find.byKey(const ValueKey('photo-preview-image')),
    );
    expect(image.image, isA<FileImage>());
    expect(find.text('1 / 2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await library.select({library.photos.last.id});
    final restored = LocalPhotoLibrary(
      directory: Directory('${temporary.path}/library'),
    );
    await restored.load();
    expect(restored.photos, hasLength(2));
    expect(restored.selected, hasLength(1));
    expect(storyFromPhotos(restored.selected).totalShots, 1);
    restored.dispose();
  });
}
