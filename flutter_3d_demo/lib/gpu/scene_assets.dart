import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../story/photo_geo.dart';
import 'gallery_math.dart';

void addStarfield(fs.Scene scene) {
  final random = math.Random(73);
  final stars = fs.InstancedMesh(
    geometry: fs.SphereGeometry(radius: 1, segments: 6, rings: 3),
    material: fs.UnlitMaterial()..baseColorFactor = vm.Vector4.all(1),
  );
  for (int i = 0; i < 2600; i++) {
    final y = random.nextDouble() * 2 - 1;
    final angle = random.nextDouble() * math.pi * 2;
    final radial = math.sqrt(1 - y * y);
    final position =
        vm.Vector3(math.cos(angle) * radial, y, math.sin(angle) * radial) * 70;
    final size = .018 + math.pow(random.nextDouble(), 3).toDouble() * .045;
    final brightness = .16 + random.nextDouble() * .55;
    stars.addInstance(
      vm.Matrix4.translation(position)..scaleByDouble(size, size, size, 1),
      color: vm.Vector4(brightness * .8, brightness * .9, brightness, 1),
    );
  }
  scene.add(
    fs.Node(name: 'starfield')
      ..raycastable = false
      ..addComponent(fs.InstancedMeshComponent(stars)),
  );
}

Future<void> initializeGalleryGpu() async {
  await fs.Scene.initializeStaticResources();
  if (!fs.Scene.isReadyToRender) {
    throw StateError('Flutter GPU 着色器尚未就绪');
  }
}

/// 每个视图持有自己的引用，卸载后释放；纹理由引擎跨视图共享。
class SceneAssets {
  static Future<Map<String, String>>? _aliases;
  final Map<String, Future<fs.TextureSource>> _textures = {};
  bool _disposed = false;

  Future<fs.TextureSource> texture(
    String path, {
    bool thumbnail = false,
  }) async {
    if (thumbnail) path = 'assets/thumbs/${path.split('/').last}';
    final aliases = await (_aliases ??= rootBundle
        .loadString('assets/texture_aliases.json')
        .then((s) => (jsonDecode(s)['aliases'] as Map).cast<String, String>()));
    final key = aliases[path] ?? path;
    if (_disposed) throw StateError('场景已关闭');
    return _textures.putIfAbsent(key, () => fs.loadTexture(key));
  }

  /// 释放本视图的一次持有；材质必须先切回缩略图，其他视图的引用不受影响。
  Future<void> release(String path) async {
    final aliases = await _aliases;
    final key = aliases?[path] ?? path;
    final pending = _textures.remove(key);
    if (pending == null) return;
    try {
      await pending;
    } catch (_) {
      return;
    }
    await fs.releaseTexture(key);
  }

  void dispose() {
    _disposed = true;
    for (final entry in _textures.entries) {
      entry.value.then(
        (_) => fs.releaseTexture(entry.key),
        onError: (Object _, StackTrace _) => false,
      );
    }
    _textures.clear();
  }
}

fs.MeshGeometry photoQuad(double width, double height) {
  final b = fs.GeometryBuilder();
  b.normal(vm.Vector3(0, 0, 1));
  for (final v in [
    (-1.0, -1.0, 0.0, 1.0),
    (1.0, -1.0, 1.0, 1.0),
    (1.0, 1.0, 1.0, 0.0),
    (-1.0, 1.0, 0.0, 0.0),
  ]) {
    // Scene 的相机使用 +Z 向前约定；从相框 +Z 正面看，U 沿 -X 增长。
    b.texCoord(vm.Vector2(1 - v.$3, v.$4));
    b.addVertex(vm.Vector3(v.$1 * width / 2, v.$2 * height / 2, 0));
  }
  return (b
        ..addTriangle(0, 1, 2)
        ..addTriangle(0, 2, 3))
      .build();
}

fs.MeshGeometry earthMesh() {
  const rows = 64, cols = 128;
  final b = fs.GeometryBuilder(deduplicate: false);
  for (int r = 0; r <= rows; r++) {
    for (int c = 0; c <= cols; c++) {
      final point = GeoPoint(90 - r * 180 / rows, -180 + c * 360 / cols);
      final normal = globePosition(point, 1);
      b.normal(normal).texCoord(vm.Vector2(c / cols, r / rows));
      b.addVertex(normal * 2);
    }
  }
  for (int r = 0; r < rows; r++) {
    for (int c = 0; c < cols; c++) {
      final a = r * (cols + 1) + c, d = a + cols + 1;
      b
        ..addTriangle(a, a + 1, d)
        ..addTriangle(a + 1, d + 1, d);
    }
  }
  return b.build();
}

fs.Scene createGalleryScene() => fs.Scene()
  // Pixel 7 Pro 实测全分辨率光栅接近 16ms；UI 保持原分辨率。
  ..renderScale = .75
  ..antiAliasingMode = fs.AntiAliasingMode.fxaa
  ..toneMapping = fs.ToneMappingMode.pbrNeutral
  ..environmentIntensity = 0.55
  ..directionalLight = fs.DirectionalLight(
    direction: vm.Vector3(-1, -2, -1),
    intensity: 2.2,
  );

fs.Node framedPhoto(
  String name,
  fs.Material photo,
  double width,
  double height,
  fs.Material frame,
) {
  final group = fs.Node(name: name);
  group.add(
    fs.Node(name: name, mesh: fs.Mesh(_frameMesh(width, height), frame)),
  );
  group.add(
    fs.Node(name: name, mesh: fs.Mesh(photoQuad(width, height), photo))
      ..position = vm.Vector3(0, 0, width * .0175),
  );
  return group;
}

// 正面是镂空的四条边，避免照片与木板正面在远处产生深度冲突。
fs.MeshGeometry _frameMesh(double width, double height) {
  final b = fs.GeometryBuilder();
  final x = width * 1.05 / 2, y = height * 1.065 / 2, z = width * .0175;
  void quad(vm.Vector3 normal, List<vm.Vector3> points) {
    b.normal(normal);
    final i = points.map(b.addVertex).toList();
    b
      ..addTriangle(i[0], i[1], i[2])
      ..addTriangle(i[0], i[2], i[3]);
  }

  quad(vm.Vector3(0, 0, -1), [
    vm.Vector3(-x, -y, -z),
    vm.Vector3(-x, y, -z),
    vm.Vector3(x, y, -z),
    vm.Vector3(x, -y, -z),
  ]);
  quad(vm.Vector3(1, 0, 0), [
    vm.Vector3(x, -y, -z),
    vm.Vector3(x, y, -z),
    vm.Vector3(x, y, z),
    vm.Vector3(x, -y, z),
  ]);
  quad(vm.Vector3(-1, 0, 0), [
    vm.Vector3(-x, -y, z),
    vm.Vector3(-x, y, z),
    vm.Vector3(-x, y, -z),
    vm.Vector3(-x, -y, -z),
  ]);
  quad(vm.Vector3(0, 1, 0), [
    vm.Vector3(-x, y, -z),
    vm.Vector3(-x, y, z),
    vm.Vector3(x, y, z),
    vm.Vector3(x, y, -z),
  ]);
  quad(vm.Vector3(0, -1, 0), [
    vm.Vector3(-x, -y, z),
    vm.Vector3(-x, -y, -z),
    vm.Vector3(x, -y, -z),
    vm.Vector3(x, -y, z),
  ]);
  void border(double l, double r, double bottom, double top) =>
      quad(vm.Vector3(0, 0, 1), [
        vm.Vector3(l, bottom, z),
        vm.Vector3(r, bottom, z),
        vm.Vector3(r, top, z),
        vm.Vector3(l, top, z),
      ]);
  border(-x, x, height / 2, y);
  border(-x, x, -y, -height / 2);
  border(-x, -width / 2, -height / 2, height / 2);
  border(width / 2, x, -height / 2, height / 2);
  return b.build();
}

vm.Vector3 orbitOffset(double yaw, double pitch, double distance) =>
    vm.Vector3(
      -math.sin(yaw) * math.cos(pitch),
      math.sin(pitch),
      math.cos(yaw) * math.cos(pitch),
    ) *
    distance;

/// 圆角照片和轻薄玻璃外壳都是三维网格，不用二维裁剪替代场景几何。
fs.Node glassPhoto(
  String name,
  fs.Material photo,
  double width,
  double height,
) {
  const steps = 8;
  List<vm.Vector2> outline(double w, double h, double radius) {
    final corners = [
      vm.Vector2(w / 2 - radius, h / 2 - radius),
      vm.Vector2(-w / 2 + radius, h / 2 - radius),
      vm.Vector2(-w / 2 + radius, -h / 2 + radius),
      vm.Vector2(w / 2 - radius, -h / 2 + radius),
    ];
    return [
      for (int c = 0; c < 4; c++)
        for (int i = 0; i <= steps; i++)
          corners[c] +
              vm.Vector2(
                    math.cos((c + i / steps) * math.pi / 2),
                    math.sin((c + i / steps) * math.pi / 2),
                  ) *
                  radius,
    ];
  }

  final inner = outline(width, height, width * .065);
  final outer = outline(width + .025, height + .025, width * .065 + .0125);
  final face = fs.GeometryBuilder(deduplicate: false);
  face.normal(vm.Vector3(0, 0, 1)).texCoord(vm.Vector2(.5, .5));
  face.addVertex(vm.Vector3.zero());
  for (final p in inner) {
    face.texCoord(vm.Vector2(.5 - p.x / width, .5 - p.y / height));
    face.addVertex(vm.Vector3(p.x, p.y, 0));
  }
  for (int i = 0; i < inner.length; i++) {
    face.addTriangle(0, i + 1, (i + 1) % inner.length + 1);
  }
  final shell = fs.GeometryBuilder(deduplicate: false);
  void quad(List<vm.Vector3> points, vm.Vector3 normal) {
    shell.normal(normal);
    final ids = points.map(shell.addVertex).toList();
    shell
      ..addTriangle(ids[0], ids[1], ids[2])
      ..addTriangle(ids[0], ids[2], ids[3]);
  }

  const thickness = .022;
  for (int i = 0; i < inner.length; i++) {
    final j = (i + 1) % inner.length;
    vm.Vector3 at(vm.Vector2 p, double z) => vm.Vector3(p.x, p.y, z);
    quad([
      at(outer[i], 0),
      at(outer[j], 0),
      at(inner[j], 0),
      at(inner[i], 0),
    ], vm.Vector3(0, 0, 1));
    final edge = outer[j] - outer[i];
    quad([
      at(outer[j], 0),
      at(outer[i], 0),
      at(outer[i], -thickness),
      at(outer[j], -thickness),
    ], vm.Vector3(edge.y, -edge.x, 0).normalized());
  }
  final back = fs.GeometryBuilder(deduplicate: false);
  back.normal(vm.Vector3(0, 0, -1));
  back.addVertex(vm.Vector3(0, 0, -thickness));
  for (final p in outer) {
    back.addVertex(vm.Vector3(p.x, p.y, -thickness));
  }
  for (int i = 0; i < outer.length; i++) {
    back.addTriangle(0, (i + 1) % outer.length + 1, i + 1);
  }
  final glass = fs.PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(.72, .86, 1, .32)
    ..metallicFactor = .05
    ..roughnessFactor = .08
    ..clearcoat = .9
    ..clearcoatRoughness = .06
    ..alphaMode = fs.AlphaMode.blend;
  final frost = fs.UnlitMaterial()
    ..baseColorFactor = vm.Vector4(.45, .63, .85, .16)
    ..alphaMode = fs.AlphaMode.blend;
  return fs.Node(name: name)
    ..add(fs.Node(name: name, mesh: fs.Mesh(face.build(), photo)))
    ..add(fs.Node(name: name, mesh: fs.Mesh(shell.build(), glass)))
    ..add(fs.Node(name: name, mesh: fs.Mesh(back.build(), frost)));
}
