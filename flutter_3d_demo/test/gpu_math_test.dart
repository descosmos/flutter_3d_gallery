import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_3d_demo/gpu/gallery_math.dart';
import 'package:flutter_3d_demo/gpu/gcj02.dart';
import 'package:flutter_3d_demo/story/photo_geo.dart';

void main() {
  test('地球顶点具有真实 XYZ、半径和正反面', () {
    final front = globePosition(const GeoPoint(0, 0));
    final back = globePosition(const GeoPoint(0, 180));
    final north = globePosition(const GeoPoint(90, 0));
    expect(front.z, closeTo(2, 1e-6));
    expect(back.z, closeTo(-2, 1e-6));
    expect(north.y, closeTo(2, 1e-6));
    for (final p in photoGeo.values) {
      final xyz = globePosition(p);
      expect(xyz.length, closeTo(2, 1e-5));
      expect([xyz.x, xyz.y, xyz.z].every((v) => v.isFinite), isTrue);
    }
  });
  test('地点分组不丢照片，细分与相机俯仰无关', () {
    final coarse = groupPhotos(12),
        medium = groupPhotos(2),
        detailed = groupPhotos(.02);
    expect(coarse.length, lessThan(medium.length));
    expect(medium.length, lessThan(detailed.length));
    for (final groups in [coarse, medium, detailed]) {
      expect(
        groups.expand((g) => g).map((e) => e.key).toSet().length,
        photoGeo.length,
      );
    }
  });
  test('照片环阵列分布于三维空间并闭合', () {
    const count = 24;
    final front = photoPosition(0, count), back = photoPosition(12, count);
    expect(front.z, greaterThan(0));
    expect(back.z, lessThan(0));
    expect((photoPosition(24, count) - front).length, lessThan(1e-5));
    expect(galleryRadius(90), greaterThan(galleryRadius(24)));
    expect(wrapAngle(3 * math.pi), closeTo(-math.pi, 1e-6));
  });
  test('GCJ 底图转换可逆，境外不偏移', () {
    const point = GeoPoint(43.8, 87.6);
    final roundtrip = Gcj02.gcj2wgs(Gcj02.wgs2gcj(point));
    expect(roundtrip.lat, closeTo(point.lat, .0001));
    expect(roundtrip.lng, closeTo(point.lng, .0001));
    const abroad = GeoPoint(0, 0);
    expect(Gcj02.wgs2gcj(abroad), same(abroad));
  });
}
