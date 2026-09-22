import 'dart:math' as math;

import '../story/photo_geo.dart';
import 'gallery_math.dart';

typedef GeoPhoto = MapEntry<String, GeoPoint>;

/// 同地点照片是不可拆分的相册；只对不同地点继续做地理层级划分。
class PhotoCluster {
  factory PhotoCluster(String id, Iterable<GeoPhoto> photos) =>
      PhotoCluster._(id, _groupLocations(photos));

  PhotoCluster._(this.id, List<List<GeoPhoto>> locations)
    : _locations = List.unmodifiable(locations),
      photos = List.unmodifiable(locations.expand((p) => p)) {
    if (photos.isEmpty) throw ArgumentError('照片分组不能为空');
  }

  final String id;
  final List<GeoPhoto> photos;
  final List<List<GeoPhoto>> _locations;
  int get count => photos.length;
  bool get isLeaf => count == 1;
  bool get isLocation => _locations.length == 1;
  late final GeoPoint center = groupCenter(photos);
  late final List<PhotoCluster> children = _split();

  List<PhotoCluster> _split() {
    if (isLocation) return const [];
    final centers = _locations.map(groupCenter).toList();
    var minLat = centers.first.lat, maxLat = minLat;
    var minLng = centers.first.lng, maxLng = minLng;
    for (final point in centers) {
      minLat = math.min(minLat, point.lat);
      maxLat = math.max(maxLat, point.lat);
      minLng = math.min(minLng, point.lng);
      maxLng = math.max(maxLng, point.lng);
    }
    final latMid = (minLat + maxLat) / 2, lngMid = (minLng + maxLng) / 2;
    final buckets = <int, List<List<GeoPhoto>>>{};
    for (int i = 0; i < centers.length; i++) {
      final p = centers[i];
      final key = (p.lat > latMid ? 2 : 0) + (p.lng > lngMid ? 1 : 0);
      (buckets[key] ??= []).add(_locations[i]);
    }
    if (buckets.length < 2) {
      // 极少数不同地点中心重合时，仍按地点划分，绝不拆开同地点照片。
      buckets.clear();
      final size = (_locations.length / 8).ceil();
      for (int i = 0; i < _locations.length; i++) {
        (buckets[i ~/ size] ??= []).add(_locations[i]);
      }
    }
    return [
      for (final e in buckets.entries) PhotoCluster._('$id/${e.key}', e.value),
    ];
  }
}

// 容纳少量 GPS 抖动；包围盒对角线不超过 50m，避免沿步行轨迹链式合并。
class _LocationBucket {
  _LocationBucket(GeoPhoto photo)
    : photos = [photo],
      referenceLng = photo.value.lng,
      minLat = photo.value.lat,
      maxLat = photo.value.lat;
  final List<GeoPhoto> photos;
  final double referenceLng;
  double minLat, maxLat, minLng = 0, maxLng = 0;

  bool add(GeoPhoto photo) {
    final p = photo.value;
    final longitude = (p.lng - referenceLng + 180) % 360 - 180;
    final south = math.min(minLat, p.lat), north = math.max(maxLat, p.lat);
    final west = math.min(minLng, longitude),
        east = math.max(maxLng, longitude);
    final y = (north - south) * 111320;
    final x =
        (east - west) * 111320 * math.cos((north + south) * math.pi / 360);
    if (x * x + y * y > 50 * 50) return false;
    photos.add(photo);
    minLat = south;
    maxLat = north;
    minLng = west;
    maxLng = east;
    return true;
  }
}

List<List<GeoPhoto>> _groupLocations(Iterable<GeoPhoto> photos) {
  final groups = <_LocationBucket>[];
  for (final photo in photos) {
    if (!groups.any((group) => group.add(photo))) {
      groups.add(_LocationBucket(photo));
    }
  }
  return [for (final group in groups) List.unmodifiable(group.photos)];
}

final _defaultLocations = _groupLocations(photoGeo.entries);

List<PhotoCluster> photoClusterRoots({
  double degrees = 12,
  Iterable<GeoPhoto>? photos,
}) {
  final groups = <(int, int), List<List<GeoPhoto>>>{};
  for (final location
      in photos == null ? _defaultLocations : _groupLocations(photos)) {
    final point = groupCenter(location);
    final key = ((point.lat / degrees).floor(), (point.lng / degrees).floor());
    (groups[key] ??= []).add(location);
  }
  return [
    for (final entry in groups.entries)
      PhotoCluster._('${entry.key.$1}:${entry.key.$2}', entry.value),
  ];
}
