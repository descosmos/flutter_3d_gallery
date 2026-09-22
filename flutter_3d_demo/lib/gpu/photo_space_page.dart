import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../pages/photo_map_shared.dart';
import '../player/particles.dart';
import '../story/photo_geo.dart';
import '../story/story_models.dart';
import 'gallery_math.dart';
import 'globe_page.dart';
import 'scene_assets.dart';
import 'photo_preview.dart';

/// 照片是有厚度相框上的纹理网格；相机、遮挡和光照都在 3D 场景中。
class GpuPhotoSpacePage extends StatefulWidget {
  const GpuPhotoSpacePage({
    super.key,
    required this.story,
    this.photos,
    this.placeName,
    this.onClose,
  });
  final StorySpec story;
  final List<PhotoMapMarker>? photos;
  final String? placeName;
  final VoidCallback? onClose;
  @override
  State<GpuPhotoSpacePage> createState() => _GpuPhotoSpacePageState();
}

class _GpuPhotoSpacePageState extends State<GpuPhotoSpacePage> {
  final _assets = SceneAssets();
  fs.Scene? _scene;
  fs.Node? _photoRing;
  Offset _doubleTapPosition = Offset.zero;
  bool get _fixedCamera => widget.photos != null;
  final _camera = fs.PerspectiveCamera();
  late final List<String> _photos;
  late final List<int> _chapters;
  final _materials = <fs.UnlitMaterial>[];
  late final List<fs.TextureSource?> _thumbnails;
  final _highResolution = <int>{};
  final _nodes = <fs.Node>[];
  double _focus = 0, _target = 0, _pitch = .16, _yaw = 0;
  double _distance = 5.8, _startDistance = 5.8;
  int _selected = 0;
  bool _ready = false, _orbit = false;
  bool _animating = true, _dragging = false;
  int _settledFrames = 0;
  String? _error;
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _photos = [];
    _chapters = [];
    if (widget.photos != null) {
      _photos.addAll(widget.photos!.map((p) => p.thumbAsset));
      _chapters.addAll(List.filled(_photos.length, 0));
    } else {
      for (int c = 0; c < widget.story.chapters.length - 1; c++) {
        for (final shot in widget.story.chapters[c].shots) {
          _photos.add(shot.asset);
          _chapters.add(c);
        }
      }
    }
    _thumbnails = List.filled(_photos.length, null, growable: true);
    _load();
  }

  Future<void> _load() async {
    try {
      await initializeGalleryGpu();
      if (!mounted) return;
      final scene = createGalleryScene();
      _scene = scene;
      _photoRing = fs.Node(name: 'photo-ring');
      scene.add(_photoRing!);
      for (int i = 0; i < _photos.length; i++) {
        final material = fs.UnlitMaterial()..doubleSided = true;
        _materials.add(material);
        final node = glassPhoto('photo:$i', material, 1.9, 1.425)
          ..position = photoPosition(i.toDouble(), _photos.length);
        node.lookAt(node.position * 2 - vm.Vector3(0, 1.6, 0));
        _nodes.add(node);
        _photoRing!.add(node);
      }
      // 分批上传，避免在 UI isolate 同一帧解码整个地点的照片。
      int next = 0;
      Future<void> worker() async {
        while (mounted && next < _photos.length) {
          final i = next++;
          final texture = await _assets.texture(_photos[i], thumbnail: true);
          if (!mounted) return;
          _materials[i].baseColorTexture = texture;
          _thumbnails[i] = texture;
          final image = texture.sampledTexture;
          if (image != null) {
            final aspect = image.width / image.height;
            final height = math.min(2.7, 1.9 / aspect);
            _nodes[i].scale = vm.Vector3(
              height * aspect / 1.9,
              height / 1.425,
              1,
            );
          }
        }
      }

      await Future.wait(List.generate(3, (_) => worker()));
      if (!mounted) return;
      _setCamera(0);
      _tick(Duration.zero, 1);
      setState(() => _ready = true);
      _loadFocus();
      debugPrint('GALLERY_GPU_READY photos=${_photos.length}');
    } catch (e, s) {
      debugPrint('GPU photo scene: $e\n$s');
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _loadFocus() async {
    if (!_ready) return;
    final index = _selected;
    if (!_photos[index].startsWith('assets/photos/')) return;
    _highResolution.add(index);
    for (final old
        in _highResolution.where((i) => (i - index).abs() > 1).toList()) {
      _materials[old].baseColorTexture = _thumbnails[old];
      _highResolution.remove(old);
      // 同一源图可能用于多个镜头，不提前释放仍在近邻镜头使用的资源。
      if (!_highResolution.any((i) => _photos[i] == _photos[old])) {
        _assets.release(_photos[old]);
      }
    }
    try {
      final texture = await _assets.texture(_photos[index]);
      if (mounted && _highResolution.contains(index)) {
        _materials[index].baseColorTexture = texture;
        _wake();
      }
    } catch (e) {
      debugPrint('GPU focus texture: $e');
    }
  }

  void _select(int index) {
    if (index < 0 || index >= _photos.length) return;
    _target = index.toDouble();
    _wake();
    if (_selected != index) {
      setState(() => _selected = index);
      _loadFocus();
    }
  }

  void _tick(Duration elapsed, double dt) {
    _focus += (_target - _focus) * (1 - math.exp(-10 * dt.clamp(0, 1)));
    if (_fixedCamera) {
      _photoRing?.rotation = vm.Quaternion.axisAngle(
        vm.Vector3(0, 1, 0),
        _focus * math.pi * 2 / _photos.length,
      );
    } else {
      _setCamera(_focus);
    }
    if (!_dragging && (_target - _focus).abs() < .0001) {
      if (++_settledFrames > 3 && _animating && mounted) {
        setState(() => _animating = false);
      }
    } else {
      _settledFrames = 0;
    }
  }

  void _setCamera(double focus) {
    final point = photoPosition(focus, _photos.length);
    final angle = focus * math.pi * 2 / _photos.length;
    _camera
      ..position = point + orbitOffset(angle + _yaw, _pitch, _distance)
      ..target = point + vm.Vector3(0, .45, 0)
      ..fovNear = .05
      ..fovFar = 45;
  }

  int? _photoAt(Offset position) {
    if (!_ready || _size == Size.zero) return null;
    final name =
        _scene!.raycast(_camera.screenPointToRay(position, _size))?.node.name ??
        '';
    return name.startsWith('photo:') ? int.tryParse(name.substring(6)) : null;
  }

  void _preview() {
    final index = _photoAt(_doubleTapPosition);
    if (index != null) showPhotoPreview(context, _photos[index]);
  }

  void _wake() {
    _settledFrames = 0;
    if (!_animating && mounted) setState(() => _animating = true);
  }

  void _pick(TapUpDetails details) {
    final index = _photoAt(details.localPosition);
    if (index != null) _select(index);
  }

  @override
  void dispose() {
    _scene?.removeAll();
    _materials.clear();
    _thumbnails.clear();
    _highResolution.clear();
    _nodes.clear();
    _assets.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.placeName ?? '3D 回忆空间';
    return Scaffold(
      backgroundColor: const Color(0xFF07101D),
      body: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(child: _GlassAmbient(asset: _photos[_selected])),
          const IgnorePointer(child: ParticleField(time: 2.4, opacity: .45)),
          if (_ready)
            LayoutBuilder(
              builder: (context, c) {
                _size = c.biggest;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _pick,
                  onDoubleTapDown: (d) => _doubleTapPosition = d.localPosition,
                  onDoubleTap: _preview,
                  onScaleStart: (_) {
                    _startDistance = _distance;
                    _dragging = true;
                    _wake();
                  },
                  onScaleUpdate: (d) {
                    if (_fixedCamera) {
                      if (d.pointerCount == 1) {
                        _target = (_target - d.focalPointDelta.dx / 90).clamp(
                          0,
                          _photos.length - 1.0,
                        );
                        final index = _target.round();
                        if (index != _selected) {
                          setState(() => _selected = index);
                        }
                      }
                      return;
                    }
                    if (d.pointerCount > 1) {
                      _distance = (_startDistance / d.scale).clamp(.8, 18);
                    } else {
                      if (_orbit) {
                        _yaw -= d.focalPointDelta.dx * .009;
                      } else {
                        _target -= d.focalPointDelta.dx / 90;
                        _target = _target.clamp(0, _photos.length - 1.0);
                        final index = _target.round();
                        if (index != _selected) {
                          setState(() => _selected = index);
                          _loadFocus();
                        }
                      }
                      _pitch = (_pitch + d.focalPointDelta.dy * .006).clamp(
                        -1.3,
                        1.3,
                      );
                    }
                  },
                  onScaleEnd: (_) {
                    _dragging = false;
                    _wake();
                    if (!_orbit) _target = _target.roundToDouble();
                  },
                  child: fs.SceneView(
                    _scene!,
                    autoTick: _animating,
                    camera: _camera,
                    onTick: _tick,
                  ),
                );
              },
            )
          else
            Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('3D 场景加载失败\n$_error'),
                    ),
            ),
          if (_ready && !_fixedCamera && _photos.length > 1)
            Positioned.fill(
              child: SafeArea(
                child: Align(
                  alignment: const Alignment(0, .18),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: BackdropGroup(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _GlassPhotoArrow(
                            label: '上一张',
                            icon: Icons.chevron_left_rounded,
                            onPressed: _selected > 0
                                ? () => _select(_selected - 1)
                                : null,
                          ),
                          _GlassPhotoArrow(
                            label: '下一张',
                            icon: Icons.chevron_right_rounded,
                            onPressed: _selected < _photos.length - 1
                                ? () => _select(_selected + 1)
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Row(
                children: [
                  IconButton(
                    tooltip: '返回',
                    onPressed:
                        widget.onClose ?? () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back_ios_new),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (widget.photos == null)
                    IconButton(
                      tooltip: '3D 照片地图',
                      icon: const Icon(Icons.public),
                      onPressed: () {
                        final key =
                            'assets/thumbs/${_photos[_selected].split('/').last}';
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => GpuGlobePage(
                              focus: photoGeo[key] ?? const GeoPoint(43, 86),
                              story: widget.story,
                            ),
                          ),
                        );
                      },
                    )
                  else
                    const SizedBox(width: 48),
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 0,
            child: SafeArea(
              child: BackdropGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.photos == null
                          ? '${widget.story.chapters[_chapters[_selected]].title} · 第 ${_selected + 1} 张'
                          : '第 ${_selected + 1} / ${_photos.length} 张',
                      style: const TextStyle(
                        fontSize: 15,
                        color: Colors.white,
                        letterSpacing: .5,
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (widget.photos == null)
                      SizedBox(
                        height: 36,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (
                              int i = 0;
                              i < widget.story.chapters.length - 1;
                              i++
                            )
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: _GlassPill(
                                  label: widget.story.chapters[i].title,
                                  selected: _chapters[_selected] == i,
                                  onTap: () => _select(_chapters.indexOf(i)),
                                ),
                              ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (!_fixedCamera)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _GlassPill(
                            label: _orbit ? '自由环绕' : '浏览照片',
                            icon: Icons.threed_rotation,
                            onTap: () => setState(() => _orbit = !_orbit),
                          ),
                          const SizedBox(width: 8),
                          _GlassPill(
                            label: '绕到背面',
                            icon: Icons.flip_camera_android_outlined,
                            onTap: () {
                              _yaw = math.pi;
                              _pitch = .25;
                              _wake();
                            },
                          ),
                          const SizedBox(width: 8),
                          Tooltip(
                            message: '重置视角',
                            child: _GlassPill(
                              icon: Icons.center_focus_strong,
                              onTap: () {
                                _yaw = 0;
                                _pitch = .16;
                                _distance = 5.8;
                                _wake();
                              },
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 12),
                    Text(
                      _fixedCamera
                          ? '左右切换照片 · 双击查看大图'
                          : _orbit
                          ? '单指环绕 · 双指靠近或远离'
                          : '左右滑动环视空间 · 双指缩放',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: .45),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassPhotoArrow extends StatelessWidget {
  const _GlassPhotoArrow({
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Container(
    width: 48,
    height: 48,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: .16),
          blurRadius: 14,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: ClipOval(
      child: BackdropFilter.grouped(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Material(
          color: Colors.white.withValues(alpha: onPressed == null ? .04 : .1),
          child: Ink(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: .24),
                width: .8,
              ),
            ),
            child: IconButton(
              tooltip: label,
              onPressed: onPressed,
              padding: EdgeInsets.zero,
              color: Colors.white.withValues(alpha: .9),
              disabledColor: Colors.white.withValues(alpha: .22),
              icon: Icon(icon, size: 28),
            ),
          ),
        ),
      ),
    ),
  );
}

class _GlassPill extends StatelessWidget {
  const _GlassPill({
    this.label,
    this.icon,
    required this.onTap,
    this.selected = false,
  });
  final String? label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool selected;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter.grouped(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: selected ? .84 : .07),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withValues(alpha: selected ? .9 : .2),
              width: .7,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) Icon(icon, size: 15, color: Colors.white70),
              if (icon != null && label != null) const SizedBox(width: 6),
              if (label != null)
                Text(
                  label!,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: selected ? const Color(0xFF142132) : Colors.white70,
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _GlassAmbient extends StatelessWidget {
  const _GlassAmbient({required this.asset});
  final String asset;
  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40),
        child: Transform.scale(
          scale: 1.35,
          child: Image.asset(
            'assets/thumbs/${asset.split('/').last}',
            fit: BoxFit.cover,
            cacheWidth: 256,
          ),
        ),
      ),
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xE607101D), Color(0x9907101D), Color(0xF207101D)],
          ),
        ),
      ),
    ],
  );
}
