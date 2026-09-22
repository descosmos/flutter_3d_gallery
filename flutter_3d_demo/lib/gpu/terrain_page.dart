import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../pages/photo_map_shared.dart';
import '../pages/terrain.dart';
import '../story/photo_geo.dart';
import '../story/story_models.dart';
import 'map_navigation.dart';
import 'map_tiles.dart';
import 'photo_space_page.dart';
import 'scene_assets.dart';
import 'photo_clusters.dart';
import 'photo_flags.dart';
import 'photo_preview.dart';

/// DEM 高程直接成为 GPU 网格的 Y 坐标，瓦片铺在同一曲面上。
class GpuTerrainPage extends StatefulWidget {
  const GpuTerrainPage({
    super.key,
    required this.focus,
    required this.story,
    this.photos,
    this.initialDistance = 17,
    this.initialPitch = .65,
  });
  final GeoPoint focus;
  final StorySpec story;
  final List<GeoPhoto>? photos;
  final double initialDistance, initialPitch;
  @override
  State<GpuTerrainPage> createState() => _GpuTerrainPageState();
}

class _GpuTerrainPageState extends State<GpuTerrainPage> {
  final _terrain = Terrain();
  final _mapStore = MapTileStore();
  final _camera = fs.PerspectiveCamera(fovNear: .02, fovFar: 160);
  fs.Scene? _scene;
  final _tileMaterials = <MapTile, fs.UnlitMaterial>{};
  fs.Node? _mapRoot;
  MapTileCoverage? _coverage;
  Timer? _regionTimer;
  final _flags = <PhotoFlag>[];
  final _flagTextures = PhotoFlagTextures();
  PhotoCluster? _flagScope, _selected;
  late final List<PhotoCluster> _rootClusters;
  final _flagHistory = <(PhotoCluster?, vm.Vector3, double, int)>[];
  Offset _doubleTapPosition = Offset.zero;
  bool _ready = false, _satellite = true, _topDown = false;
  int _loadedTiles = 0, _failedTiles = 0, _tileGeneration = 0;
  String? _error;
  double _distance = 17, _lastScale = 1, _pitch = .65, _yaw = .3;
  int _gesturePointers = 0;
  bool _pinched = false;
  final _touchPointers = <int>{};
  double _referenceHeight = 0;
  final _target = vm.Vector3.zero();
  Size _size = Size.zero;
  int _zoom = 12, _regionVersion = 0;

  GeoPoint get _center => GeoPoint(
    widget.focus.lat - _target.z / 111.32,
    widget.focus.lng -
        _target.x / (111.32 * math.cos(widget.focus.lat * math.pi / 180)),
  );

  void _syncCamera() {
    final center = _center;
    _target.y =
        (_terrain.heightAt(center.lat, center.lng) - _referenceHeight) /
        1000 *
        1.5;
    _camera
      ..fovNear = (_distance * .005).clamp(.0001, .3)
      ..fovFar = math.max(3, _distance * 8)
      ..target = _target
      ..position =
          _target + orbitOffset(_yaw, _topDown ? 1.55 : _pitch, _distance);
  }

  GeoPoint _geo(vm.Vector3 p) => GeoPoint(
    widget.focus.lat - p.z / 111.32,
    widget.focus.lng -
        p.x / (111.32 * math.cos(widget.focus.lat * math.pi / 180)),
  );

  List<PhotoCluster> get _clusters => _flagScope?.children ?? _rootClusters;

  List<GeoPoint> _coveragePoints() {
    final points = <GeoPoint>[_center];
    final lowGround = _target.y - math.min(2.0, _distance * .4);
    for (int y = 0; y <= 4; y++) {
      for (int x = 0; x <= 4; x++) {
        final screen = Offset(x * _size.width / 4, y * _size.height / 4);
        final ray = mapRay(_camera, _size, screen);
        var point = groundPoint(_camera, _size, screen, lowGround);
        if (point == null ||
            (point - _camera.position).length > _camera.fovFar) {
          point = ray.origin + ray.direction * _camera.fovFar;
        }
        points.add(_geo(point));
      }
    }
    // 真正位于视野内的照片也决定覆盖范围，不能仅截掉范围外的旗子。
    for (final cluster in _clusters) {
      final p = _position(cluster.center);
      final depth = (p - _camera.position).dot(_camera.forward);
      final screen = _camera.worldToScreen(p, _size);
      if (depth > _camera.fovNear &&
          depth < _camera.fovFar &&
          screen != null &&
          (Offset.zero & _size).inflate(60).contains(screen)) {
        points.add(cluster.center);
      }
    }
    return points;
  }

  MapTileCoverage _cover(List<GeoPoint> points) => MapTileCoverage.around(
    points,
    _center,
    (12 + math.log(17 / _distance) / math.ln2).round().clamp(8, 18),
  );

  void _scheduleRegion() {
    if (!mounted || !_ready || _regionTimer != null) return;
    _regionTimer = Timer(const Duration(milliseconds: 120), () {
      _regionTimer = null;
      if (mounted) _updateRegion();
    });
  }

  void _updateRegion() {
    _syncCamera();
    final points = _coveragePoints();
    final cover = _cover(points);
    if (_coverage?.zoom != cover.zoom || !points.every(_coverage!.contains)) {
      _load(cover: cover);
    }
  }

  @override
  void initState() {
    super.initState();
    _rootClusters = photoClusterRoots(degrees: .02, photos: widget.photos);
    _distance = widget.initialDistance.clamp(.08, 45);
    _pitch = widget.initialPitch.clamp(.12, 1.5);
    _load();
  }

  vm.Vector3 _position(GeoPoint p) => vm.Vector3(
    -(p.lng - widget.focus.lng) *
        111.32 *
        math.cos(widget.focus.lat * math.pi / 180),
    (_terrain.heightAt(p.lat, p.lng) - _referenceHeight) / 1000 * 1.5,
    -(p.lat - widget.focus.lat) * 111.32,
  );

  Future<void> _load({MapTileCoverage? cover}) async {
    final region = ++_regionVersion;
    try {
      await initializeGalleryGpu();
      if (!_terrain.loaded) await _terrain.load();
      if (!mounted || region != _regionVersion) return;
      if (!_terrain.loaded) throw StateError('无法读取 DEM 高程');
      _size = _size.isEmpty ? MediaQuery.sizeOf(context) : _size;
      _referenceHeight = _terrain.heightAt(widget.focus.lat, widget.focus.lng);
      _syncCamera();
      cover ??= _cover(_coveragePoints());
      final scene = _scene ??= (createGalleryScene()..renderScale = 1);
      final root = fs.Node(name: 'terrain-region:z${cover.zoom}');
      final materials = <MapTile, fs.UnlitMaterial>{};
      final flags = <PhotoFlag>[];
      for (final tile in cover.tiles) {
        final texture = _mapStore.cached(tile, style: _satellite ? 6 : 7);
        final material = fs.UnlitMaterial(colorTexture: texture)
          ..baseColorFactor = texture == null
              ? vm.Vector4(.13, .23, .15, 1)
              : vm.Vector4.all(1);
        materials[tile] = material;
        root.add(
          fs.Node(
            name: 'terrain-tile:${tile.zoom}/${tile.x}/${tile.y}',
            mesh: fs.Mesh(
              mapTileGeometry(
                tile,
                _position,
                shade: (p) => _terrain.shadeAt(p.lat, p.lng),
              ),
              material,
            ),
          ),
        );
      }
      for (final cluster in _clusters) {
        if (!cover.contains(cluster.center)) continue;
        final pos = _position(cluster.center);
        final ground = fs.raycastNode(
          root,
          vm.Ray.originDirection(
            pos + vm.Vector3(0, 20, 0),
            vm.Vector3(0, -1, 0),
          ),
          where: (node) => node.name.startsWith('terrain-tile:'),
        );
        if (ground == null) throw StateError('照片位置没有被地形网格覆盖: ${cluster.id}');
        final texture = await _flagTextures.forCluster(cluster);
        if (!mounted || region != _regionVersion) return;
        final flag = PhotoFlag(
          cluster,
          ground.worldPoint + vm.Vector3(0, .0005, 0),
          texture,
        );
        for (final previous in _flags) {
          if (previous.cluster.id == cluster.id) {
            flag.layoutOffset = previous.layoutOffset;
            break;
          }
        }
        flags.add(flag);
        root.add(flag.node);
      }
      if (!mounted || region != _regionVersion) return;
      // 新网格和旗子一起替换，拖动及异步加载时不会出现旗杆失去地面的中间态。
      if (_mapRoot != null) scene.remove(_mapRoot!);
      _mapRoot = root;
      scene.add(root);
      _coverage = cover;
      _zoom = cover.zoom;
      _tileMaterials
        ..clear()
        ..addAll(materials);
      _flags
        ..clear()
        ..addAll(flags);
      setState(() => _ready = true);
      _loadTiles();
      debugPrint(
        'GALLERY_GPU_READY terrain_vertices=${cover.count * 17 * 17} tiles=${cover.count}',
      );
    } catch (e, s) {
      debugPrint('GPU terrain: $e\n$s');
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _loadTiles() async {
    final generation = ++_tileGeneration;
    final style = _satellite ? 6 : 7;
    if (mounted) {
      setState(() {
        _loadedTiles = 0;
        _failedTiles = 0;
      });
    }
    final entries = _tileMaterials.entries.toList();
    int next = 0;
    Future<void> worker() async {
      while (mounted &&
          next < entries.length &&
          generation == _tileGeneration) {
        final entry = entries[next++];
        try {
          final texture = await _mapStore.load(entry.key, style: style);
          if (!mounted || generation != _tileGeneration) return;
          entry.value
            ..baseColorTexture = texture
            ..baseColorFactor = vm.Vector4.all(1);
          setState(() => _loadedTiles++);
        } catch (e) {
          if (mounted && generation == _tileGeneration) {
            setState(() => _failedTiles++);
            debugPrint('GPU terrain tile: $e');
          }
        }
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    if (mounted && generation == _tileGeneration) {
      debugPrint(
        'GALLERY_MAP_READY terrain z=$_zoom tiles=$_loadedTiles failed=$_failedTiles',
      );
    }
  }

  void _scaleStart(ScaleStartDetails d) {
    _lastScale = 1;
    _gesturePointers = d.pointerCount;
    _pinched |= d.pointerCount > 1;
  }

  void _pointerEnded(int pointer) {
    _touchPointers.remove(pointer);
    if (_touchPointers.isEmpty) _pinched = false;
  }

  void _scaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount != _gesturePointers) {
      _gesturePointers = d.pointerCount;
      _lastScale = d.scale;
      _pinched |= d.pointerCount > 1;
      return;
    }
    setState(() {
      if (d.pointerCount > 1) {
        final before = groundPoint(
          _camera,
          _size,
          d.localFocalPoint - d.focalPointDelta,
          _target.y,
        );
        final oldDistance = _distance;
        _distance = (_distance / (d.scale / _lastScale)).clamp(.08, 45);
        _syncCamera();
        final after = groundPoint(_camera, _size, d.localFocalPoint, _target.y);
        if (before != null && after != null) {
          final delta = before - after;
          // 近乎平视时，不让地平线交点把微小手势放大成数十公里跳跃。
          final limit =
              (oldDistance - _distance).abs() * 3 +
              worldUnitsPerPixel(_distance, _camera.fovRadiansY, _size.height) *
                  d.focalPointDelta.distance *
                  3;
          if (delta.length > limit && delta.length > 0) {
            delta.scale(limit / delta.length);
          }
          _target.add(delta);
          _target.x = _target.x.clamp(-500, 500);
          _target.z = _target.z.clamp(-500, 500);
        }
      } else if (!_pinched) {
        final sensitivity = worldUnitsPerPixel(
          1,
          _camera.fovRadiansY,
          _size.height,
        );
        _yaw -= d.focalPointDelta.dx * sensitivity;
        if (!_topDown) {
          _pitch = (_pitch + d.focalPointDelta.dy * sensitivity).clamp(
            .12,
            1.5,
          );
        }
      }
    });
    _lastScale = d.scale;
  }

  PhotoFlag? _flagAt(Offset position) {
    if (!_ready) return null;
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

  void _doubleTap() {
    final flag = _flagAt(_doubleTapPosition);
    if (flag == null) return;
    if (flag.cluster.isLocation) {
      showPhotoGallery(context, flag.cluster.photos.map((p) => p.key).toList());
    } else {
      _flagHistory.add((_flagScope, _target.clone(), _distance, _zoom));
      _flagScope = flag.cluster;
      _selected = null;
      _target.setFrom(_position(flag.cluster.center));
      _distance = (_distance * .45).clamp(.08, 45);
      _zoom = (12 + math.log(17 / _distance) / math.ln2).round().clamp(8, 17);
      _load();
    }
  }

  void _upLevel() {
    if (_flagHistory.isEmpty) return;
    final (scope, target, distance, zoom) = _flagHistory.removeLast();
    _flagScope = scope;
    _target.setFrom(target);
    _distance = distance;
    _zoom = zoom;
    _selected = null;
    _load();
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
    _tileGeneration++;
    _regionVersion++;
    _regionTimer?.cancel();
    _mapStore.dispose();
    _scene?.removeAll();
    _tileMaterials.clear();
    _flagTextures.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF07121D),
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
                  onScaleEnd: (_) => _updateRegion(),
                  child: fs.SceneView(
                    _scene!,
                    autoTick: false,
                    cameraBuilder: (elapsed) {
                      _syncCamera();
                      layoutPhotoFlags(_flags, _camera, _size);
                      _scheduleRegion();
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
                    child: Text('地形加载失败\n$_error'),
                  ),
          ),
        const Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xAA000000),
                    Colors.transparent,
                    Colors.transparent,
                    Color(0xAA000000),
                  ],
                  stops: [0, .15, .8, 1],
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
                  tooltip: '返回地球',
                  icon: const Icon(Icons.arrow_back_ios_new),
                  onPressed: () => Navigator.pop(context),
                ),
                Expanded(
                  child: Text(
                    '3D 地形 · ${_satellite ? '卫星' : '标准'}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
                const SizedBox(width: 48),
              ],
            ),
          ),
        ),
        Positioned(
          bottom: 0,
          left: 14,
          right: 14,
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_flagHistory.isNotEmpty)
                  TextButton.icon(
                    key: const ValueKey('terrain-cluster-up'),
                    onPressed: _upLevel,
                    icon: const Icon(Icons.undo),
                    label: const Text('返回上一级'),
                  ),
                if (_selected != null)
                  TextButton(
                    onPressed: _openPhotos,
                    child: Text('查看地点照片（${_selected!.count} 张）'),
                  ),
                if (_loadedTiles + _failedTiles < _tileMaterials.length)
                  const Text(
                    '正在加载清晰底图…',
                    style: TextStyle(color: Colors.white60),
                  ),
                if (_failedTiles > 0)
                  TextButton(
                    onPressed: _loadTiles,
                    child: const Text('底图暂未完全加载，轻触重试'),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FilledButton.tonal(
                      onPressed: () => setState(() => _topDown = !_topDown),
                      child: Text(_topDown ? '3D' : '俯视'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.tonal(
                      onPressed: () {
                        setState(() => _satellite = !_satellite);
                        _loadTiles();
                      },
                      child: Text(_satellite ? '标准图' : '卫星图'),
                    ),
                    IconButton(
                      tooltip: '重置视角',
                      onPressed: () {
                        _flagScope = null;
                        _flagHistory.clear();
                        _selected = null;
                        _distance = 17;
                        _zoom = 12;
                        _pitch = .65;
                        _yaw = .3;
                        _topDown = false;
                        _target.setZero();
                        _load();
                        setState(() {});
                      },
                      icon: const Icon(Icons.center_focus_strong),
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
