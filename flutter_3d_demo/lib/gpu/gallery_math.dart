import 'dart:math' as math;

import 'package:vector_math/vector_math.dart' as vm;

import '../story/photo_geo.dart';

/// 真实世界坐标；地球经纬度与纹理 UV 使用同一约定。
vm.Vector3 globePosition(GeoPoint point, [double radius = 2]) {
  final lat = point.lat * math.pi / 180;
  final lng = point.lng * math.pi / 180;
  return vm.Vector3(
        -math.cos(lat) * math.sin(lng),
        math.sin(lat),
        math.cos(lat) * math.cos(lng),
      ) *
      radius;
}

double galleryRadius(int count) => math.max(3.2, count * 2.3 / (2 * math.pi));

vm.Vector3 photoPosition(double index, int count) {
  final angle = index * 2 * math.pi / count;
  final r = galleryRadius(count);
  return vm.Vector3(-math.sin(angle) * r, 1.6, math.cos(angle) * r);
}

double wrapAngle(double angle) => (angle + math.pi) % (2 * math.pi) - math.pi;

List<List<MapEntry<String, GeoPoint>>> groupPhotos(double degrees) {
  final groups = <(int, int), List<MapEntry<String, GeoPoint>>>{};
  for (final entry in photoGeo.entries) {
    (groups[(
              (entry.value.lat / degrees).floor(),
              (entry.value.lng / degrees).floor(),
            )] ??=
            [])
        .add(entry);
  }
  return groups.values.toList();
}

GeoPoint groupCenter(List<MapEntry<String, GeoPoint>> group) => GeoPoint(
  group.fold<double>(0, (v, p) => v + p.value.lat) / group.length,
  group.fold<double>(0, (v, p) => v + p.value.lng) / group.length,
);
