import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../story/photo_geo.dart';
import 'gcj02.dart';
import 'async_texture.dart';

typedef MapTile = ({int zoom, int x, int y});

({double x, double y}) mapTilePoint(GeoPoint point, int zoom) {
  final p = Gcj02.wgs2gcj(point);
  final n = (1 << zoom).toDouble();
  final lat = p.lat.clamp(-85.051128, 85.051128) * math.pi / 180;
  return (
    x: (p.lng + 180) / 360 * n,
    y: (1 - math.log(math.tan(lat) + 1 / math.cos(lat)) / math.pi) / 2 * n,
  );
}

GeoPoint mapTileGeo(double x, double y, int zoom) {
  final n = (1 << zoom).toDouble();
  final t = math.pi * (1 - 2 * y / n);
  return Gcj02.gcj2wgs(
    GeoPoint(
      math.atan((math.exp(t) - math.exp(-t)) / 2) * 180 / math.pi,
      x / n * 360 - 180,
    ),
  );
}

/// 覆盖可见地面及照片锚点，超出预算时降低整层级别，不截掉覆盖范围。
class MapTileCoverage {
  const MapTileCoverage(this.zoom, this.minX, this.minY, this.maxX, this.maxY);
  final int zoom, minX, minY, maxX, maxY;
  int get count => (maxX - minX + 1) * (maxY - minY + 1);
  Iterable<MapTile> get tiles sync* {
    for (int y = minY; y <= maxY; y++) {
      for (int x = minX; x <= maxX; x++) {
        yield (zoom: zoom, x: x, y: y);
      }
    }
  }

  factory MapTileCoverage.around(
    Iterable<GeoPoint> points,
    GeoPoint center,
    int desiredZoom, {
    int padding = 1,
    int maxTiles = 128,
  }) {
    final samples = [center, ...points];
    for (int z = desiredZoom.clamp(1, 18); ; z--) {
      final n = 1 << z;
      final reference = mapTilePoint(center, z).x;
      double west = double.infinity, north = double.infinity;
      double east = double.negativeInfinity, south = double.negativeInfinity;
      for (final sample in samples) {
        final p = mapTilePoint(sample, z);
        final x = reference + (p.x - reference + n / 2) % n - n / 2;
        west = math.min(west, x);
        east = math.max(east, x);
        north = math.min(north, p.y);
        south = math.max(south, p.y);
      }
      final cover = MapTileCoverage(
        z,
        west.floor() - padding,
        (north.floor() - padding).clamp(0, n - 1),
        east.floor() + padding,
        (south.floor() + padding).clamp(0, n - 1),
      );
      if (cover.count <= maxTiles || z == 1) return cover;
    }
  }

  bool contains(GeoPoint point) {
    final p = mapTilePoint(point, zoom), n = 1 << zoom;
    final reference = (minX + maxX + 1) / 2;
    final x = reference + (p.x - reference + n / 2) % n - n / 2;
    return x >= minX && x < maxX + 1 && p.y >= minY && p.y < maxY + 1;
  }
}

int mapZoomForResolution(double latitude, double metersPerPixel) =>
    (math.log(
              156543.03392 *
                  math.cos(latitude * math.pi / 180) /
                  math.max(.01, metersPerPixel),
            ) /
            math.ln2)
        .ceil()
        .clamp(3, 18);

fs.MeshGeometry mapTileGeometry(
  MapTile tile,
  vm.Vector3 Function(GeoPoint) position, {
  int segments = 16,
  double Function(GeoPoint)? shade,
}) {
  final b = fs.GeometryBuilder(deduplicate: false);
  for (int r = 0; r <= segments; r++) {
    for (int c = 0; c <= segments; c++) {
      final point = mapTileGeo(
        tile.x + c / segments,
        tile.y + r / segments,
        tile.zoom,
      );
      b.texCoord(vm.Vector2(c / segments, r / segments));
      final light = shade?.call(point) ?? 1.0;
      b.color(vm.Vector4(light, light, light, 1));
      b.addVertex(position(point));
    }
  }
  for (int r = 0; r < segments; r++) {
    for (int c = 0; c < segments; c++) {
      final a = r * (segments + 1) + c, d = a + segments + 1;
      b
        ..addTriangle(a, a + 1, d)
        ..addTriangle(a + 1, d + 1, d);
    }
  }
  return b.build();
}

/// 两个地图视图使用相同坐标与纹理采样；请求去重，纹理引用有界。
class MapTileStore {
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  final _cache = <String, fs.TextureSource>{};
  final _pending = <String, Future<fs.TextureSource>>{};
  final _encoded = <String, Uint8List>{};
  int _gpuEpoch = 0;
  bool _disposed = false;

  bool get hasGpuWork => _cache.isNotEmpty || _pending.isNotEmpty;

  /// 离开地图近景后只保留小体积压缩图，返回时无需重新联网下载。
  void releaseGpuTextures() {
    _gpuEpoch++;
    _cache.clear();
    _pending.clear();
  }

  String _key(MapTile t, int style) =>
      '$style/${t.zoom}/${t.x % (1 << t.zoom)}/${t.y}';
  fs.TextureSource? cached(MapTile t, {int style = 6}) =>
      _cache[_key(t, style)];

  Future<fs.TextureSource> load(MapTile t, {int style = 6}) async {
    if (_disposed) throw StateError('地图已关闭');
    final key = _key(t, style);
    final existing = _cache.remove(key);
    if (existing != null) {
      _cache[key] = existing;
      return existing;
    }
    final pending = _pending[key];
    if (pending != null) return pending;
    final epoch = _gpuEpoch;
    final request = _fetch(t, style, epoch);
    _pending[key] = request;
    try {
      final texture = await request;
      if (!_disposed && epoch == _gpuEpoch) {
        _cache[key] = texture;
        while (_cache.length > 160) {
          _cache.remove(_cache.keys.first);
        }
      }
      return texture;
    } finally {
      if (identical(_pending[key], request)) _pending.remove(key);
    }
  }

  Future<fs.TextureSource> _fetch(MapTile t, int style, int epoch) async {
    final x = t.x % (1 << t.zoom);
    final key = _key(t, style);
    var bytes = _encoded.remove(key);
    if (bytes == null) {
      final request = await _http.getUrl(
        Uri.parse(
          'https://webst0${(x + t.y) % 4 + 1}.is.autonavi.com/appmaptile?style=$style&x=$x&y=${t.y}&z=${t.zoom}',
        ),
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'Flutter3DGallery/1.0');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode != 200) {
        throw HttpException('底图 HTTP ${response.statusCode}');
      }
      bytes = await consolidateHttpClientResponseBytes(response)
          .timeout(const Duration(seconds: 12));
    }
    if (!_disposed) {
      _encoded[key] = bytes;
      while (_encoded.length > 192) {
        _encoded.remove(_encoded.keys.first);
      }
    }
    if (_disposed || epoch != _gpuEpoch) throw StateError('地图请求已取消');
    final codec = await ui.instantiateImageCodec(bytes);
    final image = (await codec.getNextFrame()).image;
    codec.dispose();
    try {
      if (_disposed) throw StateError('地图已关闭');
      return await textureFromImageAsync(
        image,
        isAlive: () => !_disposed && epoch == _gpuEpoch,
        sampling: const fs.TextureSampling(
          addressMode: gpu.SamplerAddressMode.clampToEdge,
        ),
      );
    } finally {
      image.dispose();
    }
  }

  void dispose() {
    _disposed = true;
    _http.close(force: true);
    _cache.clear();
    _encoded.clear();
    _pending.clear();
  }
}
