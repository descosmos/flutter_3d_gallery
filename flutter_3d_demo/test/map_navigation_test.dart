import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_3d_demo/gpu/gallery_math.dart';
import 'package:flutter_3d_demo/gpu/map_navigation.dart';
import 'package:flutter_3d_demo/gpu/map_tiles.dart';
import 'package:flutter_3d_demo/story/photo_geo.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  test('地形覆盖扩大时不丢掉远端照片，也不固定为九块底图', () {
    const center = GeoPoint(44.6, 80.8);
    for (final distance in [45.0, 17.0, 4.0, .08]) {
      final points = [
        for (final x in [-1.0, 1.0])
          for (final y in [-1.0, 1.0])
            GeoPoint(
              center.lat + y * distance / 111.32,
              center.lng +
                  x *
                      distance /
                      (111.32 * math.cos(center.lat * math.pi / 180)),
            ),
      ];
      final zoom = (12 + math.log(17 / distance) / math.ln2).round().clamp(
        8,
        18,
      );
      final cover = MapTileCoverage.around(points, center, zoom);
      expect(points.every(cover.contains), isTrue);
      expect(cover.count, inInclusiveRange(10, 128));
    }
  });

  test('瓦片预算不足时降低级别，仍覆盖全部照片；跨日界线不会丢覆盖', () {
    final cover = MapTileCoverage.around(
      photoGeo.values,
      const GeoPoint(44, 85),
      18,
    );
    expect(photoGeo.values.every(cover.contains), isTrue);
    expect(cover.count, lessThanOrEqualTo(128));
    final crossing = [const GeoPoint(0, 179.99), const GeoPoint(0, -179.99)];
    final wrapped = MapTileCoverage.around(crossing, crossing.first, 12);
    expect(crossing.every(wrapped.contains), isTrue);
    expect(wrapped.count, lessThan(30));
  });

  test('贴近地球时，手指移动仍对应相近的屏幕位移', () {
    const center = GeoPoint(44.6, 80.8), size = Size(400, 850);
    const delta = Offset(18, 11);
    for (final altitude in [.1, .012, .003, minimumGlobeAltitude]) {
      final camera = fs.PerspectiveCamera(
        position: globePosition(center, 2 + altitude),
        target: vm.Vector3.zero(),
      );
      final marker = globePosition(center, 2.000002);
      final before = camera.worldToScreen(marker, size)!;
      final next = dragGlobe(
        center,
        delta,
        altitude,
        camera.fovRadiansY,
        size.height,
      );
      camera.position = globePosition(next, 2 + altitude);
      final movement = camera.worldToScreen(marker, size)! - before;
      expect(
        (movement - delta).distance,
        lessThan(2),
        reason: 'altitude=$altitude movement=$movement',
      );
    }
  });

  test('近距离射线不受远裁剪反矩阵精度影响，命中位置与屏幕一致', () {
    const center = GeoPoint(44.6, 80.8), size = Size(400, 850);
    final camera = fs.PerspectiveCamera(
      position: globePosition(center, 2.0003),
      target: vm.Vector3.zero(),
      fovNear: .000003,
      fovFar: 90,
    );
    for (final screen in [
      const Offset(30, 100),
      const Offset(200, 425),
      const Offset(370, 750),
    ]) {
      final hit = globePoint(camera, size, screen);
      expect(hit, isNotNull);
      expect(hit!.length, closeTo(2, .000001));
      expect((camera.worldToScreen(hit, size)! - screen).distance, lessThan(2));
    }
  });

  test('放大后请求更细的底图，最高级别不把坐标截断为低精度浮点', () {
    expect(
      mapZoomForResolution(44.6, 4),
      greaterThan(mapZoomForResolution(44.6, 400)),
    );
    const p = GeoPoint(44.60123456, 80.80123456);
    final tile = mapTilePoint(p, 18);
    final restored = mapTileGeo(tile.x, tile.y, 18);
    expect(restored.lat, closeTo(p.lat, .00005));
    expect(restored.lng, closeTo(p.lng, .00005));
    final neighbor = mapTilePoint(GeoPoint(p.lat, p.lng + .000001), 18);
    expect(neighbor.x, greaterThan(tile.x));
  });
}
