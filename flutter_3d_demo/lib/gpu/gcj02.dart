import 'dart:math' as math;

import '../story/photo_geo.dart';

class Gcj02 {
  static const double _a = 6378245.0; // 长半轴
  static const double _ee = 0.006693421622965943; // 偏心率平方

  static bool _outOfChina(double lat, double lng) =>
      lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;

  static double _tLat(double x, double y) {
    var r =
        -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * math.sqrt(x.abs());
    r +=
        (20.0 * math.sin(6.0 * x * math.pi) +
            20.0 * math.sin(2.0 * x * math.pi)) *
        2.0 /
        3.0;
    r +=
        (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) *
        2.0 /
        3.0;
    r +=
        (160.0 * math.sin(y / 12.0 * math.pi) +
            320 * math.sin(y * math.pi / 30.0)) *
        2.0 /
        3.0;
    return r;
  }

  static double _tLng(double x, double y) {
    var r =
        300.0 +
        x +
        2.0 * y +
        0.1 * x * x +
        0.1 * x * y +
        0.1 * math.sqrt(x.abs());
    r +=
        (20.0 * math.sin(6.0 * x * math.pi) +
            20.0 * math.sin(2.0 * x * math.pi)) *
        2.0 /
        3.0;
    r +=
        (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) *
        2.0 /
        3.0;
    r +=
        (150.0 * math.sin(x / 12.0 * math.pi) +
            300.0 * math.sin(x / 30.0 * math.pi)) *
        2.0 /
        3.0;
    return r;
  }

  /// WGS-84 → GCJ-02（中国境外不偏移）
  static GeoPoint wgs2gcj(GeoPoint p) {
    if (_outOfChina(p.lat, p.lng)) return p;
    var dLat = _tLat(p.lng - 105.0, p.lat - 35.0);
    var dLng = _tLng(p.lng - 105.0, p.lat - 35.0);
    final radLat = p.lat / 180.0 * math.pi;
    var magic = math.sin(radLat);
    magic = 1 - _ee * magic * magic;
    final sqrtMagic = math.sqrt(magic);
    dLat = (dLat * 180.0) / ((_a * (1 - _ee)) / (magic * sqrtMagic) * math.pi);
    dLng = (dLng * 180.0) / (_a / sqrtMagic * math.cos(radLat) * math.pi);
    return GeoPoint(p.lat + dLat, p.lng + dLng);
  }

  /// GCJ-02 → WGS-84 粗逆（同点重算偏移相减，米级误差，demo 足够）
  static GeoPoint gcj2wgs(GeoPoint p) {
    if (_outOfChina(p.lat, p.lng)) return p;
    final g = wgs2gcj(p);
    return GeoPoint(p.lat * 2 - g.lat, p.lng * 2 - g.lng);
  }
}
