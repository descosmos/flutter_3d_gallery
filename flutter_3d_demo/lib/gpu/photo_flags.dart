import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import 'photo_clusters.dart';
import 'scene_assets.dart';
import 'map_navigation.dart';

/// 旗子、旗杆与地点锚点都在 GPU 场景中；数量角标烘焙到旗面左上角。
class PhotoFlag {
  PhotoFlag(this.cluster, this.anchor, fs.Texture2D texture) {
    final name = 'flag:${cluster.id};count:${cluster.count}';
    card = fs.Node(
      name: name,
      mesh: fs.Mesh(
        photoQuad(1, .75),
        fs.UnlitMaterial(colorTexture: texture)..alphaMode = fs.AlphaMode.blend,
      ),
    );
    final gold = fs.UnlitMaterial()
      ..baseColorFactor = vm.Vector4(.9, .65, .22, 1);
    pole = fs.Node(
      name: 'pole:${cluster.id}',
      mesh: fs.Mesh(
        fs.CylinderGeometry(
          bottomRadius: 1,
          topRadius: 1,
          height: 1,
          radialSegments: 6,
        ),
        gold,
      ),
    );
    foot = fs.Node(
      name: 'anchor:${cluster.id}',
      mesh: fs.Mesh(fs.SphereGeometry(radius: 1, segments: 8, rings: 4), gold),
    )..position = anchor;
    node
      ..add(card)
      ..add(pole)
      ..add(foot);
  }
  final PhotoCluster cluster;
  final vm.Vector3 anchor;
  final node = fs.Node();
  late final fs.Node card, pole, foot;
  Rect screenRect = Rect.zero;
  Offset? layoutOffset;

  void place(
    fs.PerspectiveCamera camera,
    Size size,
    Offset center,
    double pixelWidth,
  ) {
    final depth = (anchor - camera.position).dot(camera.forward);
    if (depth <= camera.fovNear) {
      node.visible = false;
      return;
    }
    final unitsPerPixel = 2 * math.tan(camera.fovRadiansY / 2) / size.height;
    final planeDepth = math.max(
      camera.fovNear * 2,
      depth * (1 - pixelWidth * unitsPerPixel * .2),
    );
    final width = pixelWidth * unitsPerPixel * planeDepth;
    final ray = mapRay(camera, size, center);
    final toward = ray.direction.dot(camera.forward);
    final t =
        (planeDepth - (ray.origin - camera.position).dot(camera.forward)) /
        toward;
    final position = ray.origin + ray.direction * t;
    card
      ..position = position
      ..scale = vm.Vector3.all(width);
    card.lookAt(position - camera.forward, up: camera.up);
    final top = camera.worldToScreen(position, size)!;
    screenRect = Rect.fromCenter(
      center: top,
      width: pixelWidth,
      height: pixelWidth * .75,
    );
    final basis = card.globalTransform;
    final bottom = basis.transform3(vm.Vector3(0, -.375, 0));
    final direction = bottom - anchor;
    pole
      ..position = (bottom + anchor) * .5
      ..scale = vm.Vector3(
        width * .012,
        math.max(.000001, direction.length),
        width * .012,
      );
    if (direction.length2 > 1e-12) {
      pole.rotation = vm.Quaternion.fromTwoVectors(
        vm.Vector3(0, 1, 0),
        direction.normalized(),
      );
    }
    foot
      ..position = anchor
      ..scale = vm.Vector3.all(width * .035);
    node.visible = true;
  }
}

class PhotoFlagTextures {
  final _textures = <String, Future<fs.Texture2D>>{};
  Future<fs.Texture2D> forCluster(PhotoCluster cluster) =>
      _textures.putIfAbsent(
        '${cluster.photos.first.key}:${cluster.count}:${cluster.isLocation}',
        () => _make(cluster),
      );
  void clear() => _textures.clear();

  Future<fs.Texture2D> _make(PhotoCluster cluster) async {
    final data = await rootBundle.load(cluster.photos.first.key);
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      targetWidth: 256,
    );
    final image = (await codec.getNextFrame()).image;
    codec.dispose();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final stacked = cluster.isLocation && cluster.count > 1;
    if (stacked) {
      for (final rect in [
        const Rect.fromLTRB(18, 2, 254, 176),
        const Rect.fromLTRB(10, 8, 249, 182),
      ]) {
        final layer = RRect.fromRectAndRadius(rect, const Radius.circular(14));
        canvas.drawRRect(layer, Paint()..color = const Color(0xBB263B50));
        canvas.drawRRect(
          layer,
          Paint()
            ..color = const Color(0xAAE0EAF5)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
    final rect = stacked
        ? const Rect.fromLTRB(2, 16, 244, 190)
        : const Rect.fromLTWH(0, 0, 256, 192);
    final rounded = RRect.fromRectAndRadius(
      rect.deflate(2),
      const Radius.circular(14),
    );
    canvas.save();
    canvas.clipRRect(rounded);
    paintImage(canvas: canvas, rect: rect, image: image, fit: BoxFit.cover);
    canvas.restore();
    canvas.drawRRect(
      rounded,
      Paint()
        ..color = const Color(0xFFEED6A6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    final text = TextPainter(
      text: TextSpan(
        text: '${cluster.count}',
        style: const TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w700,
          color: Color(0xFF142034),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final badge = RRect.fromRectAndRadius(
      Rect.fromLTWH(rect.left, rect.top, math.max(42, text.width + 20), 40),
      const Radius.circular(12),
    );
    canvas.drawRRect(badge, Paint()..color = const Color(0xFFF6DC9A));
    text.paint(
      canvas,
      Offset(
        rect.left + (badge.width - text.width) / 2,
        rect.top + (40 - text.height) / 2,
      ),
    );
    text.dispose();
    final picture = recorder.endRecording();
    final output = await picture.toImage(256, 192);
    try {
      return await fs.Texture2D.fromImage(output);
    } finally {
      output.dispose();
      picture.dispose();
      image.dispose();
    }
  }
}

/// 让相邻地点的旗面可分别点选，旗杆始终连接真实地点。
void layoutPhotoFlags(
  List<PhotoFlag> flags,
  fs.PerspectiveCamera camera,
  Size size, {
  bool Function(vm.Vector3)? visible,
  double pixelWidth = 60,
}) {
  if (size.isEmpty) return;
  final placed = <Rect>[];
  for (final flag in flags) {
    if (visible != null && !visible(flag.anchor)) {
      flag.node.visible = false;
      continue;
    }
    final projected = camera.worldToScreen(flag.anchor, size);
    final viewport = Offset.zero & size;
    final margin = flag.layoutOffset == null ? 0.0 : pixelWidth * .6;
    if (projected == null || !viewport.inflate(margin).contains(projected)) {
      flag.node.visible = false;
      continue;
    }
    // 优先沿用相对地点的布局，轻微拖动不会反复跳到新的避让位置。
    var center =
        projected + (flag.layoutOffset ?? Offset(0, -pixelWidth * .75 - 16));
    bool placedFlag = false;
    for (int attempt = 0; attempt < 100; attempt++) {
      // 先约束到视口再做避让，否则不同候选最终夹到同一屏幕边缘。
      final edge = math.min(pixelWidth / 2 + 6, size.width / 2);
      center = Offset(
        center.dx.clamp(edge, size.width - edge),
        center.dy.clamp(100.0, math.max(100, size.height - 160.0)),
      );
      final candidate = Rect.fromCenter(
        center: center,
        width: pixelWidth + 8,
        height: pixelWidth * .75 + 8,
      );
      if (!placed.any((r) => r.overlaps(candidate))) {
        placed.add(candidate);
        placedFlag = true;
        break;
      }
      final radius = (attempt ~/ 8 + 1) * pixelWidth * .8;
      final angle = attempt * math.pi / 4;
      center =
          projected +
          Offset(
            math.cos(angle) * radius,
            -pixelWidth - math.sin(angle) * radius,
          );
    }
    if (placedFlag) {
      flag.layoutOffset = center - projected;
      flag.place(camera, size, center, pixelWidth);
    } else {
      flag.node.visible = false;
    }
  }
}
