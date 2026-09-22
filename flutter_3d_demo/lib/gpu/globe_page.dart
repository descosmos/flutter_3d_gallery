import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../pages/photo_map_shared.dart';
import '../story/photo_geo.dart';
import '../story/story_models.dart';
import 'gallery_math.dart';
import 'photo_space_page.dart';
import 'scene_assets.dart';
import 'terrain_page.dart';
import 'photo_clusters.dart';
import 'photo_flags.dart';
import 'photo_preview.dart';
import 'map_navigation.dart';
import 'map_tiles.dart';

class GpuGlobePage extends StatefulWidget {
  const GpuGlobePage({
    super.key,
    required this.focus,
    required this.story,
    this.onClose,
    this.photos,
    this.initialDistance = 12,
  });
  final GeoPoint focus;
  final StorySpec story;
  final VoidCallback? onClose;
  final List<GeoPhoto>? photos;
  final double initialDistance;
  @override
  State<GpuGlobePage> createState() => _GpuGlobePageState();
}

class _GpuGlobePageState extends State<GpuGlobePage>
    with SingleTickerProviderStateMixin {
  final _assets = SceneAssets();
  final _camera = fs.PerspectiveCamera(fovNear: .1, fovFar: 90);
  fs.Scene? _scene;
  fs.Node? _markers;
  bool _ready = false;
  String? _error;
  late double _lat, _lng;
  double _distance = 12, _lastScale = 1;
  int _gesturePointers = 0;
  bool _pinched = false;
  final _touchPointers = <int>{};
  late List<PhotoCluster> _clusters;
  final _history = <(List<PhotoCluster>, GeoPoint, double)>[];
  final _flagTextures = PhotoFlagTextures();
  final _flags = <PhotoFlag>[];
  PhotoCluster? _selected;
  late final AnimationController _fly;
  Offset _doubleTapPosition = Offset.zero;
  bool _drilling = false;
  Size _size = Size.zero;
  int _generation = 0;
  final _mapStore = MapTileStore();
  fs.Node? _detailRoot;
  final _tileGeometry = <MapTile, fs.MeshGeometry>{};
  MapTileCoverage? _detailCoverage, _requestedCoverage;
  Timer? _detailTimer;
  Timer? _retireDetailTimer;
  int _detailGeneration = 0, _detailFailures = 0;
  bool _detailLoading = false;

  @override
  void initState() {
    super.initState();
    _lat = widget.focus.lat;
    _lng = widget.focus.lng;
    _distance = widget.initialDistance.clamp(2 + minimumGlobeAltitude, 18);
    _clusters = photoClusterRoots(photos: widget.photos);
    _fly = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _load();
  }

  Future<void> _load() async {
    try {
      await initializeGalleryGpu();
      if (!mounted) return;
      final scene = createGalleryScene()
        ..renderScale = 1
        ..environmentIntensity = .6;
      addStarfield(scene);
      final earth = await _assets.texture('assets/earth_dark.jpg');
      if (!mounted) return;
      _scene = scene;
      scene.add(
        fs.Node(
          name: 'earth',
          mesh: fs.Mesh(
            earthMesh(),
            fs.PhysicallyBasedMaterial(baseColorTexture: earth)
              ..roughnessFactor = 1
              ..metallicFactor = 0,
          ),
        ),
      );
      await _rebuildMarkers();
      _tick(Duration.zero, 0);
      if (mounted) setState(() => _ready = true);
      debugPrint('GALLERY_GPU_READY earth=16384_triangles');
    } catch (e, s) {
      debugPrint('GPU globe: $e\n$s');
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _rebuildMarkers() async {
    final generation = ++_generation;
    final root = fs.Node(name: 'landmarks');
    final flags = <PhotoFlag>[];
    for (final cluster in _clusters) {
      final texture = await _flagTextures.forCluster(cluster);
      if (!mounted || generation != _generation) return;
      final flag = PhotoFlag(
        cluster,
        globePosition(cluster.center, 2.000002),
        texture,
      );
      flags.add(flag);
      root.add(flag.node);
    }
    if (_markers != null) _scene!.remove(_markers!);
    _markers = root;
    _flags
      ..clear()
      ..addAll(flags);
    _scene!.add(root);
    if (_clusters.isNotEmpty) {
      _selected ??= _clusters.reduce((a, b) {
        double d(PhotoCluster c) =>
            math.pow(c.center.lat - _lat, 2).toDouble() +
            math.pow(c.center.lng - _lng, 2).toDouble();
        return d(a) < d(b) ? a : b;
      });
    }
    if (_size.isEmpty) _size = MediaQuery.sizeOf(context);
    _tick(Duration.zero, 0);
    if (_ready && mounted) setState(() {});
  }

  void _tick(Duration elapsed, double dt) {
    _syncCamera();
    // 近景裁剪范围内没有星空，关闭整批提交即可，不改变可见画面。
    _scene?.root.getChildByName('starfield')?.visible = _distance >= 4;
    layoutPhotoFlags(
      _flags,
      _camera,
      _size,
      visible: (p) => p.dot(_camera.position - p) > 0,
    );
    _scheduleDetail();
  }

  void _syncCamera() {
    _camera
      ..position = globePosition(GeoPoint(_lat, _lng), _distance)
      ..target = vm.Vector3.zero()
      // 最近的地面在离地高度处；收紧近裁剪面，避免最大放大时深度精度吞掉旗面。
      ..fovNear = ((_distance - 2) * .25).clamp(.00001, .1)
      ..fovFar = _distance < 4 ? math.max(.05, (_distance - 2) * 8) : 90;
  }

  void _scheduleDetail() {
    if (!mounted || _size.isEmpty || _detailTimer != null) return;
    _detailTimer = Timer(const Duration(milliseconds: 120), () {
      _detailTimer = null;
      if (mounted) _updateDetail();
    });
  }

  Future<void> _updateDetail() async {
    if (_distance >= 4) {
      _detailGeneration++;
      _requestedCoverage = null;
      final wasVisible = _detailRoot?.visible ?? false;
      _detailRoot?.visible = false;
      if (_detailLoading || wasVisible) setState(() => _detailLoading = false);
      if (_detailRoot != null || _mapStore.hasGpuWork) {
        _retireDetailTimer ??= Timer(const Duration(milliseconds: 1200), () {
          _retireDetailTimer = null;
          if (!mounted || _distance < 4) return;
          if (_detailRoot != null) _scene!.remove(_detailRoot!);
          _detailRoot = null;
          _detailCoverage = null;
          _tileGeometry.clear();
          _mapStore.releaseGpuTextures();
          setState(() {});
        });
      }
      return;
    }
    _retireDetailTimer?.cancel();
    _retireDetailTimer = null;
    final center = GeoPoint(_lat, _lng);
    final samples = <GeoPoint>[center];
    for (int y = 0; y <= 4; y++) {
      for (int x = 0; x <= 4; x++) {
        final point = globePoint(
          _camera,
          _size,
          Offset(x * _size.width / 4, y * _size.height / 4),
        );
        if (point != null) samples.add(globeGeo(point));
      }
    }
    final metersPerPixel =
        worldUnitsPerPixel(
          _distance - 2,
          _camera.fovRadiansY,
          _size.height * MediaQuery.devicePixelRatioOf(context),
        ) *
        3185500;
    final cover = MapTileCoverage.around(
      samples,
      center,
      mapZoomForResolution(_lat, metersPerPixel),
    );
    if (_detailCoverage?.zoom == cover.zoom &&
        samples.every(_detailCoverage!.contains)) {
      // 拖回现有覆盖区时，取消尚未完成的异地请求，防止过时结果反复替换画面。
      if (_requestedCoverage != null &&
          !identical(_requestedCoverage, _detailCoverage)) {
        _detailGeneration++;
        _requestedCoverage = _detailCoverage;
      }
      final wasHidden = !(_detailRoot?.visible ?? false);
      _detailRoot?.visible = true;
      if (_detailLoading || wasHidden) setState(() => _detailLoading = false);
      return;
    }
    if (_requestedCoverage?.zoom == cover.zoom &&
        samples.every(_requestedCoverage!.contains)) {
      return;
    }
    final generation = ++_detailGeneration;
    _requestedCoverage = cover;
    setState(() {
      _detailLoading = true;
      _detailFailures = 0;
    });
    final root = fs.Node(name: 'globe-map:z${cover.zoom}');
    final tiles = cover.tiles.toList();
    final centerTile = mapTilePoint(center, cover.zoom);
    tiles.sort(
      (a, b) => ((a.x - centerTile.x).abs() + (a.y - centerTile.y).abs())
          .compareTo((b.x - centerTile.x).abs() + (b.y - centerTile.y).abs()),
    );
    int next = 0, failures = 0;
    Future<void> worker() async {
      while (mounted &&
          generation == _detailGeneration &&
          next < tiles.length) {
        final tile = tiles[next++];
        try {
          final texture = await _mapStore.load(tile);
          if (!mounted || generation != _detailGeneration) return;
          root.add(
            fs.Node(
              name: 'globe-tile:${tile.zoom}/${tile.x}/${tile.y}',
              mesh: fs.Mesh(
                _geometryFor(tile),
                fs.UnlitMaterial(colorTexture: texture)..doubleSided = true,
              ),
            )..raycastable = false,
          );
        } catch (e) {
          failures++;
          if (mounted && generation == _detailGeneration) {
            debugPrint('Globe map tile: $e');
          }
        }
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    if (!mounted || generation != _detailGeneration) return;
    if (root.children.isNotEmpty) {
      if (_detailRoot != null) _scene!.remove(_detailRoot!);
      _detailRoot = root;
      _scene!.add(root);
      _detailCoverage = cover;
    }
    setState(() {
      _detailLoading = false;
      _detailFailures = failures;
    });
    debugPrint(
      'GALLERY_MAP_READY globe z=${cover.zoom} tiles=${root.children.length} failed=$failures',
    );
  }

  fs.MeshGeometry _geometryFor(MapTile tile) {
    final cached = _tileGeometry.remove(tile);
    final geometry =
        cached ??
        mapTileGeometry(
          tile,
          (p) => globePosition(p, 2.000001),
          // 小范围球面曲率极低；纹理保持原级别和原分辨率。
          segments: tile.zoom >= 13 ? 2 : 16,
        );
    _tileGeometry[tile] = geometry;
    while (_tileGeometry.length > 160) {
      _tileGeometry.remove(_tileGeometry.keys.first);
    }
    return geometry;
  }

  void _scaleStart(ScaleStartDetails details) {
    _lastScale = 1;
    _gesturePointers = details.pointerCount;
    _pinched |= details.pointerCount > 1;
  }

  void _pointerEnded(int pointer) {
    _touchPointers.remove(pointer);
    if (_touchPointers.isEmpty) _pinched = false;
  }

  void _scaleUpdate(ScaleUpdateDetails d) {
    if (_drilling) return;
    if (d.pointerCount != _gesturePointers) {
      _gesturePointers = d.pointerCount;
      _lastScale = d.scale;
      _pinched |= d.pointerCount > 1;
      return;
    }
    setState(() {
      if (d.pointerCount > 1) {
        final anchor = globePoint(
          _camera,
          _size,
          d.localFocalPoint - d.focalPointDelta,
        );
        final scale = d.scale / _lastScale;
        _distance =
            2 + ((_distance - 2) / scale).clamp(minimumGlobeAltitude, 16);
        // 缩放围绕双指中心，手指下的地点不随放大滑出视野。
        if (anchor != null) {
          final before = globeGeo(anchor);
          for (int i = 0; i < 2; i++) {
            _syncCamera();
            final hit = globePoint(_camera, _size, d.localFocalPoint);
            if (hit == null) break;
            final after = globeGeo(hit);
            _lat = (_lat + before.lat - after.lat).clamp(-85, 85);
            final longitudeDelta = (before.lng - after.lng + 180) % 360 - 180;
            _lng = (_lng + longitudeDelta + 180) % 360 - 180;
          }
          return;
        }
      } else if (_pinched) {
        return;
      }
      final center = dragGlobe(
        GeoPoint(_lat, _lng),
        d.focalPointDelta,
        _distance - 2,
        _camera.fovRadiansY,
        _size.height,
      );
      _lat = center.lat;
      _lng = center.lng;
    });
    _lastScale = d.scale;
  }

  PhotoFlag? _flagAt(Offset position) {
    if (!_ready || _size.isEmpty) return null;
    final name = _scene!.raycast(mapRay(_camera, _size, position))?.node.name;
    for (final flag in _flags) {
      if (flag.card.name == name) return flag;
    }
    return null;
  }

  void _pick(TapUpDetails d) {
    final flag = _flagAt(d.localPosition);
    if (flag != null) setState(() => _selected = flag.cluster);
  }

  Future<void> _doubleTap() async {
    final flag = _flagAt(_doubleTapPosition);
    if (flag == null || _drilling) return;
    final cluster = flag.cluster;
    if (cluster.isLocation) {
      await showPhotoGallery(
        context,
        cluster.photos.map((p) => p.key).toList(),
      );
      return;
    }
    final previous = (_clusters, GeoPoint(_lat, _lng), _distance);
    _drilling = true;
    final fromLat = _lat, fromLng = _lng, fromDistance = _distance;
    final center = cluster.center;
    final toDistance =
        2 + math.max(minimumGlobeAltitude, (_distance - 2) * .42);
    void animate() {
      final t = Curves.easeInOutCubic.transform(_fly.value);
      setState(() {
        _lat = fromLat + (center.lat - fromLat) * t;
        _lng = fromLng + (center.lng - fromLng) * t;
        _distance = fromDistance + (toDistance - fromDistance) * t;
      });
    }

    _fly.addListener(animate);
    try {
      await _fly.forward(from: 0).orCancel;
      if (!mounted) return;
      _history.add(previous);
      _clusters = cluster.children;
      _selected = null;
      await _rebuildMarkers();
    } on TickerCanceled {
      // 页面关闭会取消飞行动画。
    } finally {
      _fly.removeListener(animate);
      _drilling = false;
    }
  }

  Future<void> _upLevel() async {
    if (_drilling || _history.isEmpty) return;
    final (clusters, center, distance) = _history.removeLast();
    _clusters = clusters;
    _lat = center.lat;
    _lng = center.lng;
    _distance = distance;
    _selected = null;
    await _rebuildMarkers();
  }

  void _openPhotos() {
    final group = _selected;
    if (group == null) return;
    if (group.isLocation) {
      showPhotoGallery(context, group.photos.map((p) => p.key).toList());
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GpuPhotoSpacePage(
          story: widget.story,
          placeName: '地点照片',
          photos: [
            for (final p in group.photos)
              PhotoMapMarker(storyIndex: -1, thumbAsset: p.key, point: p.value),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _generation++;
    _fly.dispose();
    _detailTimer?.cancel();
    _retireDetailTimer?.cancel();
    _detailGeneration++;
    _mapStore.dispose();
    _tileGeometry.clear();
    _flagTextures.clear();
    _scene?.removeAll();
    _assets.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF030810),
    body: Stack(
      fit: StackFit.expand,
      children: [
        if (_ready)
          LayoutBuilder(
            builder: (context, c) {
              _size = c.biggest;
              return Listener(
                onPointerDown: (e) {
                  _touchPointers.add(e.pointer);
                  _pinched |= _touchPointers.length > 1;
                },
                onPointerUp: (e) => _pointerEnded(e.pointer),
                onPointerCancel: (e) => _pointerEnded(e.pointer),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _pick,
                  onDoubleTapDown: (d) => _doubleTapPosition = d.localPosition,
                  onDoubleTap: _doubleTap,
                  onScaleStart: _scaleStart,
                  onScaleUpdate: _scaleUpdate,

                  child: fs.SceneView(
                    _scene!,
                    autoTick: false,
                    cameraBuilder: (elapsed) {
                      _tick(elapsed, 0);
                      return _camera;
                    },
                  ),
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
                    child: Text('地球加载失败\n$_error'),
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
                  icon: const Icon(Icons.arrow_back_ios_new),
                  onPressed: widget.onClose ?? () => Navigator.pop(context),
                ),
                const Expanded(
                  child: Text(
                    '3D 照片地球',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '回到旅行区域',
                  icon: const Icon(Icons.my_location),
                  onPressed: _drilling
                      ? null
                      : () {
                          _lat = widget.focus.lat;
                          _lng = widget.focus.lng;
                          _distance = 12;
                          _history.clear();
                          _clusters = photoClusterRoots(photos: widget.photos);
                          _selected = null;
                          _rebuildMarkers();
                          setState(() {});
                        },
                ),
              ],
            ),
          ),
        ),
        Positioned(
          bottom: 0,
          left: 16,
          right: 16,
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_detailLoading)
                  const Text(
                    '正在加载清晰底图…',
                    style: TextStyle(fontSize: 11, color: Colors.white60),
                  ),
                if (_distance < 4 && !_detailLoading && _detailFailures > 0)
                  TextButton(
                    onPressed: () {
                      _detailCoverage = null;
                      _requestedCoverage = null;
                      _scheduleDetail();
                    },
                    child: const Text('底图暂未完全加载，轻触重试'),
                  ),
                Text(
                  '${widget.photos?.length ?? photoGeo.length} 个照片点位 · 当前分组 ${_selected?.count ?? 0} 张',
                ),
                if (_history.isNotEmpty)
                  TextButton.icon(
                    key: const ValueKey('cluster-up'),
                    onPressed: _upLevel,
                    icon: const Icon(Icons.undo, size: 16),
                    label: const Text('返回上一级'),
                  ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FilledButton.tonal(
                      onPressed: _selected == null ? null : _openPhotos,
                      child: const Text('查看地点照片'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => GpuTerrainPage(
                            focus: GeoPoint(_lat, _lng),
                            story: widget.story,
                          ),
                        ),
                      ),
                      child: const Text('进入地形'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  '双击展开地点 · 同地点照片悬浮浏览',
                  style: TextStyle(fontSize: 11, color: Colors.white60),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
