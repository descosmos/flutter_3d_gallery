import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../story/photo_geo.dart';

const globeRadius = 2.0;
const minimumGlobeAltitude = .0003;

double worldUnitsPerPixel(double depth, double fovY, double viewportHeight) =>
    2 * depth * math.tan(fovY / 2) / math.max(1, viewportHeight);

/// 近距离地图直接用相机基向量构造射线，避免远近裁剪比造成反矩阵精度损失。
vm.Ray mapRay(fs.PerspectiveCamera camera, Size size, Offset screen) {
  final forward = camera.forward;
  final right = camera.up.cross(forward).normalized();
  final up = forward.cross(right).normalized();
  final vertical = math.tan(camera.fovRadiansY / 2);
  final x =
      (screen.dx / size.width * 2 - 1) * vertical * size.width / size.height;
  final y = (1 - screen.dy / size.height * 2) * vertical;
  return vm.Ray.originDirection(
    camera.position.clone(),
    (forward + right * x + up * y).normalized(),
  );
}

GeoPoint dragGlobe(
  GeoPoint center,
  Offset delta,
  double altitude,
  double fovY,
  double viewportHeight,
) {
  final degrees =
      (worldUnitsPerPixel(altitude, fovY, viewportHeight) /
              globeRadius *
              180 /
              math.pi)
          .clamp(0.0, .22);
  final latitude = (center.lat + delta.dy * degrees).clamp(-85.0, 85.0);
  final longitude =
      center.lng -
      delta.dx * degrees / math.max(.1, math.cos(center.lat * math.pi / 180));
  return GeoPoint(latitude, (longitude + 180) % 360 - 180);
}

vm.Vector3? groundPoint(
  fs.PerspectiveCamera camera,
  Size size,
  Offset screen,
  double height,
) {
  final ray = mapRay(camera, size, screen);
  if (ray.direction.y.abs() < 1e-6) return null;
  final t = (height - ray.origin.y) / ray.direction.y;
  return t > 0 ? ray.origin + ray.direction * t : null;
}

vm.Vector3? globePoint(fs.PerspectiveCamera camera, Size size, Offset screen) {
  final ray = mapRay(camera, size, screen);
  final b = ray.origin.dot(ray.direction);
  final discriminant = b * b - ray.origin.length2 + globeRadius * globeRadius;
  if (discriminant < 0) return null;
  final t = -b - math.sqrt(discriminant);
  return t >= 0 ? ray.origin + ray.direction * t : null;
}

GeoPoint globeGeo(vm.Vector3 p) => GeoPoint(
  math.asin((p.y / p.length).clamp(-1.0, 1.0)) * 180 / math.pi,
  math.atan2(-p.x, p.z) * 180 / math.pi,
);
