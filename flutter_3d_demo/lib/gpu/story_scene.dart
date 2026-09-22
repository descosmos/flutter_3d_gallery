import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../story/story_models.dart';
import 'scene_assets.dart';

/// 镜头时间线驱动真实相机穿过空间中的照片网格。
class GpuStoryScene extends StatefulWidget {
  const GpuStoryScene({
    super.key,
    required this.story,
    required this.time,
    required this.parallax,
  });
  final StorySpec story;
  final double time;
  final Offset parallax;
  @override
  State<GpuStoryScene> createState() => _GpuStorySceneState();
}

class _GpuStorySceneState extends State<GpuStoryScene> {
  final _assets = SceneAssets();
  final _camera = fs.PerspectiveCamera(fovNear: .05, fovFar: 180);
  fs.Scene? _scene;
  late final List<ShotSpec> _shots;
  final _nodes = <fs.Node>[];
  final _positions = <vm.Vector3>[];
  String? _error;
  bool _ready = false;
  bool _wasConverging = false;

  @override
  void initState() {
    super.initState();
    _shots = [for (final chapter in widget.story.chapters) ...chapter.shots];
    _load();
  }

  Future<void> _load() async {
    try {
      await initializeGalleryGpu();
      if (!mounted) return;
      final scene = createGalleryScene();
      _scene = scene;
      final frame = fs.PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(.2, .14, .06, 1)
        ..metallicFactor = .6;
      scene.add(
        fs.Node(
          mesh: fs.Mesh(
            fs.PlaneGeometry(width: 35, depth: _shots.length * 16.0 + 40),
            fs.PhysicallyBasedMaterial()
              ..baseColorFactor = vm.Vector4(.02, .035, .06, 1)
              ..roughnessFactor = .8,
          ),
        )..position = vm.Vector3(0, -.1, -(_shots.length - 1) * 8.0),
      );
      for (int i = 0; i < _shots.length; i++) {
        final shot = _shots[i];
        final texture = await _assets.texture(shot.asset);
        if (!mounted) return;
        final position = vm.Vector3(math.sin(i * .8) * 3, 2, -i * 16.0);
        _positions.add(position);
        final image = texture.sampledTexture;
        final aspect = image == null ? 4 / 3 : image.width / image.height;
        final width = math.min(2.7, 2.66 * aspect);
        final node = framedPhoto(
          'shot:$i',
          fs.UnlitMaterial(colorTexture: texture),
          width,
          width / aspect,
          frame,
        )..position = position;
        _nodes.add(node);
        scene.add(node);
        if (shot.template == ShotTemplate.cardSpace) {
          for (int j = 0; j < shot.extraAssets.length; j++) {
            final texture = await _assets.texture(
              shot.extraAssets[j],
              thumbnail: true,
            );
            if (!mounted) return;
            scene.add(
              framedPhoto(
                  'extra:$i:$j',
                  fs.UnlitMaterial(colorTexture: texture),
                  1.6,
                  1.2,
                  frame,
                )
                ..position =
                    position +
                    vm.Vector3(j.isEven ? -2.3 : 2.3, j.isEven ? .6 : -.3, -1.5)
                ..rotation = vm.Quaternion.axisAngle(
                  vm.Vector3(0, 1, 0),
                  j.isEven ? .4 : -.4,
                ),
            );
          }
        }
      }
      if (mounted) setState(() => _ready = true);
      debugPrint('GALLERY_GPU_READY story_meshes=${_nodes.length}');
    } catch (e, s) {
      debugPrint('GPU story: $e\n$s');
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _tick(Duration elapsed, double dt) {
    final loc = widget.story.locate(widget.time);
    final index = loc.globalShotIndex.clamp(0, _shots.length - 1);
    final shot = _shots[index];
    final target = _positions[index].clone();
    final enter = Curves.easeInOutCubic.transform(
      (loc.localTime / .9).clamp(0, 1),
    );
    if (index > 0 && enter < 1) {
      target.setFrom(_positions[index - 1] * (1 - enter) + target * enter);
    }
    final p = loc.progress;
    final orbit =
        shot.template == ShotTemplate.microOrbit ||
        shot.template == ShotTemplate.cardSpace;
    final dx = orbit ? math.sin((p - .5) * 1.2) * 2.0 : (.5 - p) * .6;
    final distance = shot.template == ShotTemplate.cardSpace
        ? 13.0
        : shot.template == ShotTemplate.dollyIn
        ? 10 - p * 1.3
        : 9.2;
    final lift = enter < 1 ? math.sin(enter * math.pi) * 4 : 0.0;
    _camera
      ..target = target
      ..position =
          target +
          vm.Vector3(
            dx + widget.parallax.dx * 1.5,
            .3 + lift + widget.parallax.dy * .8,
            distance,
          );
    final converging = shot.template == ShotTemplate.converge;
    if (converging || _wasConverging) {
      for (int i = 0; i < _nodes.length; i++) {
        if (shot.template == ShotTemplate.converge && i != index) {
          final spread = (1 - Curves.easeInOutCubic.transform(p)) * 5;
          _nodes[i].position =
              target +
              vm.Vector3(
                math.sin(i * 2.4) * spread,
                math.cos(i * 2.4) * spread * .6,
                -1 - (i % 5) * .3,
              );
        } else {
          _nodes[i].position = _positions[i];
        }
      }
    }
    _wasConverging = converging;
  }

  @override
  void dispose() {
    _scene?.removeAll();
    _nodes.clear();
    _assets.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ready
      ? fs.SceneView(
          _scene!,
          autoTick: false,
          cameraBuilder: (elapsed) {
            _tick(elapsed, 0);
            return _camera;
          },
        )
      : Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('3D 场景加载失败\n$_error'),
                ),
        );
}
