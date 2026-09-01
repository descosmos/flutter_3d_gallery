// 3D 地球照片地图：自绘纹理球体 + 立在球面上的照片地标牌。
// 全平台统一实现（纯 Flutter，不依赖原生地图 SDK）：拖动旋转地球、
// 双指缩放、点按地标牌飞往拍摄地、双击放大浏览，632 个拍摄点点云铺底。
// 连续放大越过阈值后从球体交叉淡入"飞行视角地面平面地图"（OSM/高德
// 栅格瓦片 + 墨卡托单应投影，可一路放到街道级），缩回时反向混合。
import 'dart:io' show HttpClient, HttpHeaders;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show consolidateHttpClientResponseBytes;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show rootBundle;

import '../story/photo_geo.dart';
import '../story/place_names.dart';
import 'location_photo_space.dart';
import 'photo_map_shared.dart';
import 'terrain.dart';

/// 单位球面上的三维点
class _V3 {
  const _V3(this.x, this.y, this.z);

  final double x, y, z;

  _V3 operator *(double s) => _V3(x * s, y * s, z * s);
}

/// GCJ-02（火星坐标）转换：高德栅格瓦片为 GCJ-02，照片 GPS 与 OSM 为
/// WGS-84。切到高德源时地标/中心需偏移对齐，否则街道级会偏出几百米。
class _Gcj02 {
  static const double _a = 6378245.0; // 长半轴
  static const double _ee = 0.006693421622965943; // 偏心率平方

  static bool _outOfChina(double lat, double lng) =>
      lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;

  static double _tLat(double x, double y) {
    var r = -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * math.sqrt(x.abs());
    r += (20.0 * math.sin(6.0 * x * math.pi) +
            20.0 * math.sin(2.0 * x * math.pi)) *
        2.0 /
        3.0;
    r += (20.0 * math.sin(y * math.pi) + 40.0 * math.sin(y / 3.0 * math.pi)) *
        2.0 /
        3.0;
    r += (160.0 * math.sin(y / 12.0 * math.pi) +
            320 * math.sin(y * math.pi / 30.0)) *
        2.0 /
        3.0;
    return r;
  }

  static double _tLng(double x, double y) {
    var r = 300.0 +
        x +
        2.0 * y +
        0.1 * x * x +
        0.1 * x * y +
        0.1 * math.sqrt(x.abs());
    r += (20.0 * math.sin(6.0 * x * math.pi) +
            20.0 * math.sin(2.0 * x * math.pi)) *
        2.0 /
        3.0;
    r += (20.0 * math.sin(x * math.pi) + 40.0 * math.sin(x / 3.0 * math.pi)) *
        2.0 /
        3.0;
    r += (150.0 * math.sin(x / 12.0 * math.pi) +
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

/// 墨卡托地面平面 + 俯视相机（飞行视角）投影模型。
/// 地面坐标 = 连续缩放 z 下的墨卡托像素（z 级世界为 256·2^z px）；相机
/// 北向上、固定倾角，焦距使屏幕中心处水平 1 地面 px ≈ 1 屏幕 px。
class _MapCam {
  _MapCam({
    required this.cx,
    required this.cy,
    required this.z,
    required this.screenCenter,
    required this.camH,
    this.hRef = 0,
    double tiltDeg = 55,
  })  : tiltRad = tiltDeg * math.pi / 180,
        _sinT = math.sin(tiltDeg * math.pi / 180),
        _cosT = math.cos(tiltDeg * math.pi / 180) {
    // 相机中心纬度下的墨卡托局部比例（投影保角 → 各向同性），
    // 用于把海拔米数换算成地面 px 垂直位移
    metersPerGroundPx = metersPerGroundPxAt(
        worldToLatLng(Offset(cx, cy), z).lat, z);
    terrainHScale = terrainHScaleFor(tiltDeg);
  }

  /// 地形垂直夸张系数（Google Earth 风格）
  static const double verticalExaggeration = 1.5;

  /// 地形启用的倾角区间（度）：低于 start 完全平面，full 以上全高
  static const double _terrainTiltStart = 15;
  static const double _terrainTiltFull = 35;

  /// 指定倾角下的地形高度系数（0 = 平面，verticalExaggeration = 全高）。
  /// 低于 15° 不启用（2D/浅倾走平面快速路径），15→35° smoothstep 淡入。
  static double terrainHScaleFor(double tiltDeg) {
    final t = ((tiltDeg - _terrainTiltStart) /
            (_terrainTiltFull - _terrainTiltStart))
        .clamp(0.0, 1.0);
    return t * t * (3 - 2 * t) * verticalExaggeration;
  }

  /// 指定纬度/缩放下的墨卡托局部比例（米/地面 px，投影保角各向同性）
  static double metersPerGroundPxAt(double latDeg, double z) =>
      40075016.686 * math.cos(latDeg * math.pi / 180) / _worldSize(z);

  /// 相机中心纬度下 1 地面 px 对应的米数
  late final double metersPerGroundPx;

  /// 当前倾角下的地形高度系数（0 = 平面，verticalExaggeration = 全高）
  late final double terrainHScale;

  /// 海拔（米）→ 地面 px 垂直位移（含夸张系数与倾角淡入）
  double elevationToPx(double hMeters) =>
      hMeters * terrainHScale / metersPerGroundPx;

  /// 相机对准的地面点（墨卡托 px）
  final double cx, cy;

  /// 连续缩放级（slippy z，可取小数）
  final double z;

  /// 屏幕中心（画布坐标）
  final Offset screenCenter;

  /// 相机离地高度（墨卡托 px），决定地平线位置与透视压缩。
  /// 以地形基准面（hRef）为起点：camH-hRel 即相机相对地面点的竖直距离。
  final double camH;

  /// 地形基准面高度（地面 px）：相机中心点处的地表海拔位移。
  /// 相机几何（光轴、地平线、焦距）全部相对该基准面，因此中心点地形
  /// 恒投影到屏幕中心（与平面情形一致），只有相对中心的地势起伏显现；
  /// 高海拔地区街道级视角下相机不会"钻进山体"。
  final double hRef;

  /// 自垂直方向的倾角（rad）：55° = 倾斜飞行视角（3D），0 = 垂直俯视（2D）。
  /// tilt=0 时单应退化为纯缩放+平移（地平线推到无穷远），投影全程解析无迭代。
  final double tiltRad;
  final double _sinT, _cosT;

  /// 相机地面足迹在中心点南侧的距离
  double get _d => camH * _sinT / _cosT;

  /// 焦距（屏幕 px）
  double get _focal => camH / _cosT;

  /// 中心点地面深度（地标大小/远近排序的比例基准）
  double get referenceZ => camH / _cosT;

  /// 整数瓦片层：取连续 z 的 floor（限制在服务可用范围内）
  int get zInt => z.floor().clamp(3, 17);

  /// 当前连续 z 下一张瓦片的地面 px 边长
  double get tileGround => 256.0 * math.pow(2.0, z - zInt).toDouble();

  /// 可视远距（地面 px）：更远处的地面已压缩到不可辨，不再取瓦片
  double get maxFar => 6.5 * tileGround;

  /// 地面点的相机深度（沿视线方向，越小越近）。hPx 为地形海拔位移
  /// （地面 px）；相对基准面的高差 hRel = hPx - hRef 决定抬升量，
  /// 抬高 = 点向相机靠近，深度与高度同减。
  double depthOf(double wx, double wy, [double hPx = 0]) =>
      -(wy - cy - _d) * _sinT + (camH - (hPx - hRef)) * _cosT;

  /// 地面墨卡托 px（可带地形海拔位移 hPx）→ 屏幕坐标；
  /// 点在相机近裁剪面后返回 null
  Offset? project(double wx, double wy, [double hPx = 0]) {
    final hRel = hPx - hRef;
    final camZ = -(wy - cy - _d) * _sinT + (camH - hRel) * _cosT;
    if (camZ < _focal * 0.02) return null;
    final camY = -(wy - cy - _d) * _cosT - (camH - hRel) * _sinT;
    return screenCenter +
        Offset(_focal * (wx - cx) / camZ, -_focal * camY / camZ);
  }

  /// 屏幕坐标 → 地面墨卡托 px。地平线以上/相机后方钳制到可视边界，
  /// 保证手势反解与瓦片范围计算稳定。
  /// tilt=0（2D 垂直俯视）时 denom ≡ -cosT < 0，永不进地平线分支，
  /// 退化为纯缩放+平移，可见范围即屏幕四角反投影出的轴对齐矩形；
  /// 此时远距钳制上界 ÷sinT 得 +∞，clamp 自动失效，无需特判。
  Offset unproject(Offset s) {
    final a = (s.dx - screenCenter.dx) / _focal;
    final b = -(s.dy - screenCenter.dy) / _focal;
    // b = camY/camZ = (-vy·cosT - H·sinT) / (-vy·sinT + H·cosT)，解 vy
    final denom = b * _sinT - _cosT;
    double vy;
    if (denom >= 0) {
      // 地平线以上：视线不与地面相交，取可视远距（北）
      vy = -_d - maxFar;
    } else {
      vy = camH * (_sinT + b * _cosT) / denom;
      // 近裁剪在相机正下方偏南，远裁剪在可视远距
      vy = vy.clamp(-_d - maxFar, camH * (_cosT - 0.05) / _sinT);
    }
    final camZ = -vy * _sinT + camH * _cosT;
    return Offset(cx + a * camZ, cy + _d + vy);
  }

  // ---- Web 墨卡托（EPSG:3857 的 slippy 像素形式）----

  static const double maxLat = 85.05112878;

  static double _worldSize(double z) => 256.0 * math.pow(2.0, z).toDouble();

  static Offset latLngToWorld(GeoPoint p, double z) {
    final s = _worldSize(z);
    final lat = p.lat.clamp(-maxLat, maxLat) * math.pi / 180;
    final t = math.tan(lat);
    final asinh = math.log(t + math.sqrt(t * t + 1));
    return Offset((p.lng + 180) / 360 * s, (1 - asinh / math.pi) / 2 * s);
  }

  static GeoPoint worldToLatLng(Offset w, double z) {
    final s = _worldSize(z);
    final e = math.exp(math.pi * (1 - 2 * w.dy / s));
    final lat = math.atan((e - 1 / e) / 2) * 180 / math.pi;
    return GeoPoint(lat, w.dx / s * 360 - 180);
  }
}

class GlobePhotoMap extends StatefulWidget {
  const GlobePhotoMap({
    super.key,
    required this.markers,
    required this.focusIndex,
    required this.onSelectStory,
    required this.onClose,
  });

  final List<PhotoMapMarker> markers;
  final int focusIndex;
  final ValueChanged<int> onSelectStory;
  final VoidCallback onClose;

  @override
  State<GlobePhotoMap> createState() => _GlobePhotoMapState();
}

class _GlobePhotoMapState extends State<GlobePhotoMap>
    with TickerProviderStateMixin {
  /// 相机到球心距离（球半径为 1 的世界单位）
  static const double _camDist = 3.2;

  /// 飞行后的目标缩放（球体模式）
  static const double _flyZoom = 2.6;

  /// 球→地图交叉淡化带（_zoom 2.6→3.6）
  static const double _blendStart = 2.6;
  static const double _blendEnd = 3.6;

  /// 地图模式单卡飞入的目标 zoom（≈ slippy z15.4 街道级）
  static const double _flyZoomStreet = 7.2;

  /// 瓦片请求 UA（OSM 政策要求自定义 User-Agent）
  static const String _tileUa =
      'flutter_3d_demo/1.0 (photo memory map; contact: local-dev@example.com)';

  late double _rotX; // 绕屏幕 X 轴（俯仰，北纬为正）
  late double _rotY; // 绕屏幕 Y 轴（经度方向）
  double _zoom = 1.0;
  double _zoomAtStart = 1.0; // 捏合手势开始时的缩放基准

  ui.Image? _earth;

  late final Ticker _ticker;
  Duration? _lastTick;
  double _velX = 0, _velY = 0; // 惯性角速度（rad/s）
  Offset _panVel = Offset.zero; // 地图模式平移速度（屏幕 px/s）
  Size _lastSize = Size.zero;
  DateTime _lastTouch = DateTime.now();
  bool _interacted = false; // 用户是否已主动交互过

  late final AnimationController _fly;
  double _flyFromRX = 0, _flyFromRY = 0, _flyFromZ = 1;
  double _flyToRX = 0, _flyToRY = 0, _flyToZ = 1;
  int _lastFlownStoryIndex = -1;

  /// 当前手势序列的累计位移（<12px 视为轻击；input 注入/手指微抖也会
  /// 产生 sub-pixel move 事件，不能用"有无 move"判断）
  double _gestureTravel = 0;

  /// 手势起点（轻击命中地名标签时的屏幕位置）
  Offset _gestureStartFocal = Offset.zero;

  /// 地图模式相机俯仰角（自垂直方向，度）：55 = 倾斜 3D 视角，0 = 垂直
  /// 俯视 2D。2D/3D 切换由 _tilt 驱动 600ms easeInOutCubic 动画，每帧经
  /// _buildCam 传给 _MapCam，瓦片/地标/点云投影自然跟随。
  double _tiltDeg = 55;
  double _tiltFrom = 55, _tiltTo = 55;
  late final AnimationController _tilt;

  /// 地点照片 3D 浏览器（LocationPhotoSpace）当前展示的照片组与地名
  List<PhotoMapMarker>? _spaceMembers;
  String _spacePlaceName = '';

  /// 全部地标：photoGeo 632 张全量并入；故事镜头按 thumbAsset 映射回
  /// storyIndex，其余照片 storyIndex=-1（永不匹配焦点、不联动故事页）。
  /// 只在 initState / markers 变化时重建，不随帧重算。
  late List<PhotoMapMarker> _allMarkers;

  /// 球体全景大聚合组（纯屏幕距离产物，非真实地点，可达数百张）进入
  /// LocationPhotoSpace 前的等距抽样上限（保留首尾）。地图模式的地点
  /// 网格组是真实拍摄地，传全量 members 不抽样。
  static const int _spaceMaxPhotos = 60;

  /// 地图模式（blend>0.5）地理网格聚合的网格边长（度）：0.02° ≈ 2km。
  /// 同一网格（同一地点）的照片永远聚成一张卡，缩放不再拆分。
  static const double _clusterGridDeg = 0.02;

  /// 地理网格聚合组（_rebuildAllMarkers 时重建，不随帧/缩放变化）。
  /// 地图模式直接使用；球体模式仍用屏幕距离聚合（全景大组符合预期）。
  late List<_GeoGroup> _geoGroups;

  void _rebuildAllMarkers() {
    final storyByThumb = <String, int>{};
    for (final m in widget.markers) {
      storyByThumb[m.thumbAsset] = m.storyIndex;
    }
    final merged = <PhotoMapMarker>[
      for (final entry in photoGeo.entries)
        PhotoMapMarker(
          storyIndex: storyByThumb[entry.key] ?? -1,
          thumbAsset: entry.key,
          point: entry.value,
        ),
    ];
    // 兜底：故事镜头缩略图不在 photoGeo 时也不能丢（正常不会发生）
    for (final m in widget.markers) {
      if (!photoGeo.containsKey(m.thumbAsset)) merged.add(m);
    }
    _allMarkers = merged;
    _rebuildGeoGroups();
  }

  /// 按 [_clusterGridDeg] 地理网格把全部地标分桶：同格即同一地点，
  /// 组锚点 = 成员质心。只随 markers 重建，因此组在任何缩放级别稳定。
  void _rebuildGeoGroups() {
    final byCell = <(int, int), List<PhotoMapMarker>>{};
    for (final m in _allMarkers) {
      final key = (
        (m.point.lat / _clusterGridDeg).floor(),
        (m.point.lng / _clusterGridDeg).floor(),
      );
      (byCell[key] ??= []).add(m);
    }
    _geoGroups = [
      for (final members in byCell.values)
        _GeoGroup(
          members: members,
          centroid: GeoPoint(
            members.fold<double>(0, (s, m) => s + m.point.lat) /
                members.length,
            members.fold<double>(0, (s, m) => s + m.point.lng) /
                members.length,
          ),
          // 默认代表：故事镜头优先，否则首张（与屏幕距离聚合同优先级；
          // 焦点代表随 focusIndex 动态判断，见 repFor）
          baseRep: members.firstWhere((m) => m.storyIndex >= 0,
              orElse: () => members.first),
        ),
    ];
  }

  static bool _sameMarkers(List<PhotoMapMarker> a, List<PhotoMapMarker> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].storyIndex != b[i].storyIndex ||
          a[i].thumbAsset != b[i].thumbAsset ||
          a[i].point != b[i].point) {
        return false;
      }
    }
    return true;
  }

  // ---- 瓦片加载（HTTP 双源兜底 + LRU 内存缓存）----
  final Map<String, ui.Image> _tileCache = {}; // 插入序即 LRU 顺序
  final Set<String> _tileLoading = {};
  final Set<String> _tilePending = {}; // 并发满时的等待队列（插入序 FIFO）
  final Map<String, DateTime> _tileFailedAt = {}; // 失败 30s 内不重试
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  /// 瓦片缓存上限：每张 256×256×4 ≈ 256KB 纹理，150 张 ≈ 37MB。
  /// 实测 zoom 急推时在途解码瞬时 +24MB（并发无上限所致），故并发限 8 路、
  /// 等待队列限 160：在途峰值 ≈ 8×(256KB+HTTP 缓冲) ~几 MB，快速飞行不再风暴。
  static const int _tileCacheMax = 150;
  static const int _tileConcurrent = 8;
  static const int _tilePendingMax = 160;

  /// 瓦片缓存版本号：缓存内容变化时 +1，供画笔 shouldRepaint 值比较
  /// （瓦片到位/淘汰时其他视觉输入都没变，必须靠它触发重绘）
  int _tileVersion = 0;
  int _tileSource = 0; // 0 = OSM，1 = 高德
  int _tileFailStreak = 0;
  /// 高德瓦片样式：7 = 标准地图，6 = 卫星影像（均为不透明底图；
  /// style=8 是透明路网叠加层，不能单用）。OSM 源无卫星样式，忽略此值。
  int _tileStyle = 7;

  /// 离线 DEM 地形（assets/terrain.bin）：3D 倾斜视角下地图平面隆起成
  /// 真实山体。未加载完成时地形自动退化为平面，不影响其他功能。
  final Terrain _terrain = Terrain();

  /// 地形网格地面数据缓存（key = 源/z/x/y，源不同 GCJ 偏移采样不同）。
  /// 只存 zInt 层的世界 px + 高程 + 坡向明暗（不随相机变）；屏幕位置
  /// 每帧由当前相机投影重建。LRU 上限 120 张（每张约 4.6KB，纯堆对象）。
  final Map<String, _TerrainMesh> _meshCache = {};

  @override
  void initState() {
    super.initState();
    _rebuildAllMarkers();
    // 初始视角对准当前焦点地标（退化为全部地标质心）
    final start = _focusPoint() ?? _centroid();
    _rotX = (start.lat * math.pi / 180).clamp(-1.35, 1.35);
    _rotY = -start.lng * math.pi / 180;

    _ticker = createTicker(_onTick)..start();
    _fly = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 950))
      ..addListener(() {
        final t = Curves.easeInOutCubic.transform(_fly.value);
        setState(() {
          _rotX = ui.lerpDouble(_flyFromRX, _flyToRX, t)!;
          _rotY = ui.lerpDouble(_flyFromRY, _flyToRY, t)!;
          _zoom = ui.lerpDouble(_flyFromZ, _flyToZ, t)!;
        });
      });
    _tilt = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600))
      ..addListener(() {
        final t = Curves.easeInOutCubic.transform(_tilt.value);
        setState(() => _tiltDeg = ui.lerpDouble(_tiltFrom, _tiltTo, t)!);
      });
    _loadEarth();
    _terrain.load().then((_) {
      if (mounted) setState(() {}); // 地形就绪后重绘（此前按平面渲染）
    });
  }

  Future<void> _loadEarth() async {
    final data = await rootBundle.load('assets/earth_dark.jpg');
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(),
      targetWidth: 2048,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    if (mounted) setState(() => _earth = frame.image);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _fly.dispose();
    _tilt.dispose();
    _http.close(force: true);
    _earth?.dispose(); // 8MB 纹理：不 dispose 每次进页泄漏一张
    for (final img in _tileCache.values) {
      img.dispose();
    }
    _tileCache.clear();
    super.dispose();
  }

  GeoPoint? _focusPoint() {
    for (final m in widget.markers) {
      if (m.storyIndex == widget.focusIndex) return m.point;
    }
    return null;
  }

  GeoPoint _centroid() {
    if (widget.markers.isEmpty) return const GeoPoint(43.0, 86.0);
    double lat = 0, lng = 0;
    for (final m in widget.markers) {
      lat += m.point.lat;
      lng += m.point.lng;
    }
    return GeoPoint(lat / widget.markers.length, lng / widget.markers.length);
  }

  @override
  void didUpdateWidget(GlobePhotoMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 故事镜头列表内容变化时重建合并地标（故事页每帧新建 List，
    // 需按内容比较避免每帧重算 632 条）
    if (!_sameMarkers(oldWidget.markers, widget.markers)) {
      _rebuildAllMarkers();
    }
    // 外部（故事页）焦点变化 → 地球飞向新焦点
    if (widget.focusIndex != oldWidget.focusIndex &&
        widget.focusIndex != _lastFlownStoryIndex) {
      final p = _focusPoint();
      if (p != null) _flyTo(p, widget.focusIndex, select: false);
    }
  }

  // ---- 球体数学 ----

  static _V3 _latLngToUnit(double lat, double lng) {
    final phi = lat * math.pi / 180;
    final lambda = lng * math.pi / 180;
    return _V3(
        math.cos(phi) * math.sin(lambda), math.sin(phi),
        math.cos(phi) * math.cos(lambda));
  }

  /// 先绕 Y 轴转 _rotY，再绕 X 轴转 _rotX
  _V3 _rotate(_V3 v) {
    final cy = math.cos(_rotY), sy = math.sin(_rotY);
    final x1 = v.x * cy + v.z * sy;
    final z1 = -v.x * sy + v.z * cy;
    final cx = math.cos(_rotX), sx = math.sin(_rotX);
    return _V3(x1, v.y * cx - z1 * sx, v.y * sx + z1 * cx);
  }

  Offset _project(_V3 v, double rPix, Offset center) {
    final persp = _camDist / (_camDist - v.z);
    return center + Offset(v.x * rPix * persp, -v.y * rPix * persp);
  }

  // ---- 球→地图模式混合与相机 ----

  /// 0 = 纯球体，1 = 纯地图，过渡带内交叉淡化
  double get _mapBlend =>
      ((_zoom - _blendStart) / (_blendEnd - _blendStart)).clamp(0.0, 1.0);

  /// 连续 slippy 缩放映射：globe zoom 3.0 ≈ z4.4，zoom 8.0 = z17.5（街道级）
  double get _mapZ => 4.4 + (_zoom - 3.0) * 2.62;

  /// 屏幕中心对应的地理位置。球体朝向（_rotX/_rotY）与地图中心是同一
  /// 状态的两种读法，因此过渡天然连续、无需额外同步。
  GeoPoint get _centerGeo {
    final lng = (-_rotY * 180 / math.pi + 180) % 360 - 180;
    return GeoPoint(_rotX * 180 / math.pi, lng);
  }

  /// 瓦片坐标系：OSM 为 WGS-84，高德瓦片需 GCJ-02（火星坐标）
  GeoPoint _toTileCrs(GeoPoint p) => _tileSource == 1 ? _Gcj02.wgs2gcj(p) : p;
  GeoPoint _fromTileCrs(GeoPoint p) =>
      _tileSource == 1 ? _Gcj02.gcj2wgs(p) : p;

  _MapCam _buildCam(Size size) {
    final center = _centerGeo; // WGS-84
    final w = _MapCam.latLngToWorld(_toTileCrs(center), _mapZ);
    // 地形基准面 = 中心点地表海拔位移：相机几何全部相对该基准面，
    // 高海拔地区（如祁连山 3000m）街道级视角下相机不会钻进山体，
    // 中心点投影与平面情形逐像素一致。
    final hRef = _terrain.loaded
        ? _terrain.heightAt(center.lat, center.lng) *
            _MapCam.terrainHScaleFor(_tiltDeg) /
            _MapCam.metersPerGroundPxAt(center.lat, _mapZ)
        : 0.0;
    return _MapCam(
      cx: w.dx,
      cy: w.dy,
      z: _mapZ,
      screenCenter: _mapCenter(size),
      camH: size.height * 0.36,
      hRef: hRef,
      tiltDeg: _tiltDeg,
    );
  }

  /// Google Earth 式 2D/3D 切换：55° ⇄ 0° 俯仰动画（600ms easeInOutCubic）。
  /// 动画中途点按直接从当前角度折返；按钮标签由目标态 _tiltTo 决定。
  void _toggleTilt() {
    setState(() {
      _tiltFrom = _tiltDeg;
      _tiltTo = _tiltTo == 0.0 ? 55.0 : 0.0;
    });
    _tilt.forward(from: 0);
    _interacted = true;
  }

  /// 以地面墨卡托 px 重设中心（地图模式平移/缩放锚定共用），
  /// 写回 _rotX/_rotY 使球体朝向与地图中心保持一致。
  void _setCenterFromWorld(Offset w, double z) {
    final wgs = _fromTileCrs(_MapCam.worldToLatLng(w, z));
    var newRY = -wgs.lng * math.pi / 180;
    while (newRY - _rotY > math.pi) {
      newRY -= 2 * math.pi;
    }
    while (newRY - _rotY < -math.pi) {
      newRY += 2 * math.pi;
    }
    _rotX = (wgs.lat * math.pi / 180).clamp(-1.4, 1.4);
    _rotY = newRY;
  }

  // ---- 瓦片加载 ----

  /// 瓦片内存缓存（LRU 上限 [_tileCacheMax] 张）；未命中返回 null 并触发后台加载。
  /// key 含源与样式，切图层（标准⇄卫星）天然各自缓存，无需清空。
  /// 并发加载限 [_tileConcurrent] 路，超出进 [_tilePending] 等待队列，
  /// 避免混合带/快速飞行时一帧发起数百个 HTTP+解码造成内存尖峰。
  ui.Image? _tileAt(int z, int x, int y) {
    final key = '$_tileSource/$_tileStyle/$z/$x/$y';
    final hit = _tileCache.remove(key);
    if (hit != null) {
      _tileCache[key] = hit; // LRU：重新插到尾部
      return hit;
    }
    if (_tileLoading.contains(key) || _tilePending.contains(key)) return null;
    final failedAt = _tileFailedAt[key];
    if (failedAt != null &&
        DateTime.now().difference(failedAt).inSeconds < 30) {
      return null;
    }
    if (_tileLoading.length < _tileConcurrent) {
      _loadTile(key);
    } else if (_tilePending.length < _tilePendingMax) {
      _tilePending.add(key);
    }
    // 队列也满则放弃：视野还在高速移动，下一帧会以最新位置重试
    return null;
  }

  /// 并发槽释放后启动等待中的请求（丢弃已缓存/切源前滞留的 key）。
  /// 由 _loadTile 的 finally 驱动，因此无需重绘也能消化完等待队列。
  void _pumpTileQueue() {
    while (_tileLoading.length < _tileConcurrent && _tilePending.isNotEmpty) {
      final key = _tilePending.first;
      _tilePending.remove(key);
      if (_tileCache.containsKey(key) || _tileLoading.contains(key)) continue;
      if (!key.startsWith('$_tileSource/$_tileStyle/')) continue;
      _loadTile(key);
    }
  }

  /// 加载单张瓦片。key 格式 '源/样式/z/x/y'（从 key 解析坐标与源，
  /// 等待队列里被切源废弃的请求在 _pumpTileQueue 已被前缀过滤）。
  Future<void> _loadTile(String key) async {
    _tileLoading.add(key);
    try {
      final p = key.split('/');
      final src = int.parse(p[0]), style = int.parse(p[1]);
      final z = int.parse(p[2]), x = int.parse(p[3]), y = int.parse(p[4]);
      final url = src == 0
          ? 'https://tile.openstreetmap.org/$z/$x/$y.png'
          // style=7 不透明标准地图，style=6 不透明卫星影像（JPEG）；
          // style=8 是透明路网叠加层（不能单用）
          : 'https://webst0${1 + (x + y) % 4}.is.autonavi.com/appmaptile'
              '?lang=zh_cn&size=1&scale=1&style=$style&x=$x&y=$y&z=$z';
      final req = await _http.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, _tileUa);
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        throw StateError('瓦片请求失败 HTTP ${resp.statusCode}');
      }
      final bytes = await consolidateHttpClientResponseBytes(resp);
      final codec = await ui.instantiateImageCodec(bytes,
          targetWidth: 256, targetHeight: 256);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _tileCache[key] = frame.image;
        _tileVersion++;
        while (_tileCache.length > _tileCacheMax) {
          _tileCache.remove(_tileCache.keys.first)?.dispose();
        }
        _tileFailStreak = 0;
      });
    } catch (_) {
      _tileFailedAt[key] = DateTime.now();
      if (_tileFailedAt.length > 400) _tileFailedAt.clear(); // 防无界增长
      // 当前源连续失败 → 自动切换兜底源
      if (++_tileFailStreak >= 6 && mounted) {
        setState(() {
          _tileSource = 1 - _tileSource;
          _tileFailStreak = 0;
          _evictStaleNamespaces();
        });
      }
    } finally {
      _tileLoading.remove(key);
      _pumpTileQueue();
    }
  }

  /// 切源/切样式后主动释放失效命名空间的瓦片纹理（仅保留最近 24 张供
  /// 快速切回），并丢弃等待队列里已失效的请求，避免旧源纹理长期占位。
  void _evictStaleNamespaces() {
    final ns = '$_tileSource/$_tileStyle/';
    _tilePending.removeWhere((k) => !k.startsWith(ns));
    final stale = _tileCache.keys.where((k) => !k.startsWith(ns)).toList();
    var kept = 0;
    for (final key in stale.reversed) {
      // 迭代序即 LRU 顺序，倒序 = 最新优先保留
      if (kept >= 24) {
        _tileCache.remove(key)?.dispose();
        _tileVersion++;
      } else {
        kept++;
      }
    }
  }

  // ---- 手势与动画 ----

  void _onTick(Duration elapsed) {
    if (!mounted || _fly.isAnimating) {
      _lastTick = elapsed;
      return;
    }
    final dt = _lastTick == null
        ? 0.0
        : math.min((elapsed - _lastTick!).inMicroseconds / 1e6, 0.05);
    _lastTick = elapsed;
    if (dt <= 0) return;

    if (_mapBlend > 0) {
      // 地图模式：平移惯性；停用球体自转与旋转惯性
      _velX = _velY = 0;
      if (_panVel.distance > 1.5 && _lastSize != Size.zero) {
        setState(() {
          final cam = _buildCam(_lastSize);
          final c = cam.screenCenter;
          final g0 = cam.unproject(c - _panVel * dt);
          final g1 = cam.unproject(c);
          _setCenterFromWorld(Offset(cam.cx, cam.cy) + (g0 - g1), cam.z);
          final decay = math.pow(0.08, dt).toDouble();
          _panVel *= decay;
        });
      }
      return;
    }

    final speed = math.sqrt(_velX * _velX + _velY * _velY);
    if (speed > 0.002) {
      // 惯性旋转，指数衰减
      setState(() {
        _rotX = (_rotX + _velX * dt).clamp(-1.45, 1.45);
        _rotY += _velY * dt;
        final decay = math.pow(0.08, dt).toDouble();
        _velX *= decay;
        _velY *= decay;
      });
    } else if (_zoom < 1.3 &&
        DateTime.now().difference(_lastTouch).inMilliseconds >
            (_interacted ? 15000 : 6000)) {
      // 仅在全景时缓慢自转（放大浏览区域时不打扰，且极慢保证地标牌可点）
      setState(() => _rotY += 0.008 * dt);
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    _fly.stop();
    _velX = _velY = 0;
    _panVel = Offset.zero;
    _lastTouch = DateTime.now();
    _gestureTravel = 0;
    _gestureStartFocal = details.focalPoint;
    _zoomAtStart = _zoom; // scale 是相对手势起点的累积系数，需缓存基准
  }

  /// 单点轻击（累计位移 <12px）结束时：命中地名标签则飞往该地点。
  /// 复用 scale 手势通道，避免 TapGestureRecognizer 与捏合竞争。
  void _onScaleEnd(ScaleEndDetails details) {
    if (_gestureTravel > 12 || _lastSize == Size.zero) return;
    _tryFlyToPlaceLabel(
        _gestureStartFocal, _mapCenter(_lastSize), _rPix(_lastSize));
  }

  void _onScaleUpdate(ScaleUpdateDetails details, Size size) {
    _lastTouch = DateTime.now();
    _interacted = true;
    _gestureTravel += details.focalPointDelta.distance;
    if (_mapBlend > 0) {
      _onMapScaleUpdate(details, size);
      return;
    }
    setState(() {
      if ((details.scale - 1.0).abs() > 0.001) {
        final newZoom = (_zoomAtStart * details.scale).clamp(0.7, 8.0);
        if (newZoom != _zoom) {
          // 锚定手势焦点（zoom-to-focal-point）：缩放系数 k 会把球面内容
          // 从焦点 F 推向 C+(F-C)*k，补一个旋转 Δ=(F-C)*(1-k) 把内容拉回 F，
          // 使焦点下的球面内容在屏幕上基本不动（换算与拖动手势一致）。
          final k = newZoom / _zoom;
          final delta = (details.focalPoint - _mapCenter(size)) * (1 - k);
          final rPixNew = _rPix(size, newZoom);
          _rotY += delta.dx / rPixNew;
          _rotX = (_rotX + delta.dy / rPixNew).clamp(-1.45, 1.45);
          _zoom = newZoom;
        }
      } else {
        final rPix = _rPix(size);
        _rotY += details.focalPointDelta.dx / rPix;
        _rotX = (_rotX + details.focalPointDelta.dy / rPix).clamp(-1.45, 1.45);
        // 平滑跟踪拖动角速度供惯性使用
        final vx = details.focalPointDelta.dy / rPix * 60;
        final vy = details.focalPointDelta.dx / rPix * 60;
        _velX = _velX * 0.7 + vx * 0.3;
        _velY = _velY * 0.7 + vy * 0.3;
      }
    });
  }

  /// 地图模式手势：单指拖动 = 沿地面平移（内容跟手），双指捏合 =
  /// 继续放大（可一直到 z17 街道级）。反解用单应的平移等价性，精确无迭代。
  void _onMapScaleUpdate(ScaleUpdateDetails details, Size size) {
    setState(() {
      final cam = _buildCam(size);
      if ((details.scale - 1.0).abs() > 0.001) {
        final newZoom = (_zoomAtStart * details.scale).clamp(0.7, 8.0);
        if (newZoom != _zoom) {
          // 焦点地面点锚定：先反解焦点下的地理位置，换新 z 后再把它放回焦点
          final focalGeo =
              _MapCam.worldToLatLng(cam.unproject(details.focalPoint), cam.z);
          _zoom = newZoom;
          final cam2 = _buildCam(size);
          final rel = cam2.unproject(details.focalPoint) -
              Offset(cam2.cx, cam2.cy);
          final focalW2 = _MapCam.latLngToWorld(focalGeo, cam2.z);
          _setCenterFromWorld(focalW2 - rel, cam2.z);
        }
        _panVel = Offset.zero;
      } else {
        // 平移：让焦点下的地面点跟随手指
        final g0 =
            cam.unproject(details.focalPoint - details.focalPointDelta);
        final g1 = cam.unproject(details.focalPoint);
        _setCenterFromWorld(Offset(cam.cx, cam.cy) + (g0 - g1), cam.z);
        // 平滑跟踪拖动速度供惯性使用
        final v = details.focalPointDelta * 60;
        _panVel = _panVel * 0.7 + v * 0.3;
      }
    });
  }

  void _flyTo(GeoPoint p, int storyIndex,
      {bool select = true, double? zoom}) {
    _lastFlownStoryIndex = select ? storyIndex : _lastFlownStoryIndex;
    _velX = _velY = 0;
    var targetRY = -p.lng * math.pi / 180;
    // 取最短经度路径
    while (targetRY - _rotY > math.pi) {
      targetRY -= 2 * math.pi;
    }
    while (targetRY - _rotY < -math.pi) {
      targetRY += 2 * math.pi;
    }
    _flyFromRX = _rotX;
    _flyFromRY = _rotY;
    _flyFromZ = _zoom;
    _flyToRX = (p.lat * math.pi / 180).clamp(-1.35, 1.35);
    _flyToRY = targetRY;
    // 已放大时保持当前缩放，避免点卡片时突兀拉远；
    // 地图模式下单卡直接深入街道级（≈ z15.4）
    _flyToZ = zoom ??
        (_zoom >= 3.0
            ? math.max(_zoom, _flyZoomStreet)
            : (_zoom > _flyZoom ? _zoom : _flyZoom));
    _fly.forward(from: 0);
    _interacted = true;
    if (select) widget.onSelectStory(storyIndex);
  }

  // ---- 布局 ----

  /// 球心在画布中的位置（与 build / 手势锚定共用，避免两处不一致）
  Offset _mapCenter(Size size) => Offset(size.width / 2, size.height * 0.46);

  double _rPix(Size size, [double? zoom]) =>
      math.min(size.width, size.height) * 0.34 * (zoom ?? _zoom);

  /// 计算地标牌布局：球面/地图双模式投影后按 blend 插值（过渡不跳变）。
  /// 聚合策略随 blend 切换：球体模式（blend<=0.5）按屏幕距离聚合（全景
  /// 大组符合预期）；地图模式（blend>0.5）按地理网格聚合，同一地点在
  /// 任何缩放级别都是一张卡（混合带内允许重组一次，组引用稳定不闪烁）。
  List<_LandmarkLayout> _layoutLandmarks(
      double rPix, Offset center, Size size) {
    const clusterDist = 48.0; // 屏幕像素阈值
    final blend = _mapBlend;
    final cam = blend > 0 ? _buildCam(size) : null;
    if (blend > 0.5 && cam != null) {
      return _layoutByGeoGrid(rPix, center, cam, blend, size);
    }
    // 旗杆高度换算成世界单位，保证屏幕上恒定 ~34px（不随缩放变长）
    final poleH = 34.0 / rPix;
    final projected = <_LandmarkLayout>[];
    for (final m in _allMarkers) {
      final lm = _projectAnchor(m, [m], rPix, center, cam, blend, poleH, size);
      if (lm != null) projected.add(lm);
    }
    // 近的优先成组
    projected.sort((a, b) => b.depth.compareTo(a.depth));
    final clusters = <_LandmarkLayout>[];
    for (final lm in projected) {
      _LandmarkLayout? hit;
      for (final c in clusters) {
        if ((c.top - lm.top).distance < clusterDist) {
          hit = c;
          break;
        }
      }
      if (hit == null) {
        clusters.add(lm);
      } else {
        hit.members.add(lm.rep);
        // 代表优先级：焦点 > 故事镜头 > 普通照片（同级保留更近的——
        // projected 已按近优先排序，先来者是更近的）。故事优先保证球体
        // 全景时大聚合组的封面是故事精选照而非随机普通照。
        if (widget.focusIndex >= 0 &&
            lm.rep.storyIndex == widget.focusIndex) {
          hit.rep = lm.rep;
        } else if (hit.rep.storyIndex < 0 && lm.rep.storyIndex >= 0) {
          hit.rep = lm.rep;
        }
      }
    }
    // 组锚点改用成员质心，牌面看起来更居中
    for (final c in clusters) {
      if (c.members.length > 1) {
        double lat = 0, lng = 0;
        for (final m in c.members) {
          lat += m.point.lat;
          lng += m.point.lng;
        }
        final anchor = _projectAnchor(
            c.rep, c.members, rPix, center, cam, blend, poleH, size,
            at: GeoPoint(lat / c.members.length, lng / c.members.length));
        if (anchor != null) {
          c.base = anchor.base;
          c.top = anchor.top;
        }
      }
    }
    // 近的后画（在 Stack 中压在远的上面）
    clusters.sort((a, b) => a.depth.compareTo(b.depth));
    return clusters;
  }

  /// 地图模式地标布局：每格一组直接成卡（锚点=组质心），不做屏幕距离
  /// 合并，因此缩放/平移/俯仰都不会拆分或合并地点组，徽标计数稳定。
  /// 投影/剔除/远近排序与球体路径共用 _projectAnchor。
  List<_LandmarkLayout> _layoutByGeoGrid(
      double rPix, Offset center, _MapCam cam, double blend, Size size) {
    final poleH = 34.0 / rPix;
    final clusters = <_LandmarkLayout>[];
    for (final g in _geoGroups) {
      final lm = _projectAnchor(g.repFor(widget.focusIndex), g.members, rPix,
          center, cam, blend, poleH, size,
          at: g.centroid);
      if (lm != null) clusters.add(lm);
    }
    // 近的后画（在 Stack 中压在远的上面）
    clusters.sort((a, b) => a.depth.compareTo(b.depth));
    return clusters;
  }

  /// 单个锚点的双模式投影：球面与地图各算一份，按 blend 插值。
  /// [at] 可覆盖锚点位置（聚合组质心）；返回 null 表示不可见。
  _LandmarkLayout? _projectAnchor(
    PhotoMapMarker rep,
    List<PhotoMapMarker> members,
    double rPix,
    Offset center,
    _MapCam? cam,
    double blend,
    double poleH,
    Size size, {
    GeoPoint? at,
  }) {
    final p = at ?? rep.point;
    final r = _rotate(_latLngToUnit(p.lat, p.lng));
    if (cam == null && r.z <= 0.03) return null; // 纯球体：背面不显示

    // 球面一侧（过渡带内背面也算——投影仍有效，供插值用）
    final sBase = _project(r, rPix, center);
    final sTop = _project(r * (1 + poleH), rPix, center);
    final sDepth = r.z.clamp(0.0, 1.0);
    final sPersp = _camDist / (_camDist - r.z);
    final sOpacity = ((r.z - 0.03) / 0.22).clamp(0.0, 1.0);

    Offset base = sBase, top = sTop;
    double depth = sDepth, persp = sPersp, opacity = sOpacity;

    if (cam != null) {
      final w = _MapCam.latLngToWorld(_toTileCrs(p), cam.z);
      // 地标锚定地形高度：DEM 为 WGS-84 网格，直接采样未偏移的锚点；
      // 倾角 <15° 时 elevationToPx 为 0，自然退化为平面锚定
      final hPx = cam.elevationToPx(_terrain.heightAt(p.lat, p.lng));
      final proj = cam.project(w.dx, w.dy, hPx);
      final usable = proj != null && (blend < 1 || !_offScreen(proj, size));
      if (blend >= 1 && !usable) return null; // 纯地图：剔除后方与屏幕外
      if (usable) {
        final mBase = proj;
        final mTop = proj + const Offset(0, -40); // 旗杆改屏幕竖直向上
        final camZ = cam.depthOf(w.dx, w.dy, hPx);
        // 1 = 屏幕中心深度；近大远小
        final mDepth = (cam.referenceZ / camZ).clamp(0.0, 1.6);
        if (blend >= 1) {
          base = mBase;
          top = mTop;
          depth = mDepth;
          persp = mDepth;
          opacity = 1.0;
        } else {
          base = Offset.lerp(sBase, mBase, blend)!;
          top = Offset.lerp(sTop, mTop, blend)!;
          depth = ui.lerpDouble(sDepth, mDepth, blend)!;
          persp = ui.lerpDouble(sPersp, mDepth, blend)!;
          opacity = ui.lerpDouble(sOpacity, 1.0, blend)!;
        }
      }
    }
    return _LandmarkLayout(
        members: members,
        rep: rep,
        base: base,
        top: top,
        depth: depth,
        persp: persp,
        opacity: opacity);
  }

  /// 屏幕外剔除（留边距供聚合展开后仍可见）
  bool _offScreen(Offset p, Size size) =>
      p.dx < -360 ||
      p.dx > size.width + 360 ||
      p.dy < -460 ||
      p.dy > size.height + 460;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _lastSize = size;
        final center = _mapCenter(size);
        final rPix = _rPix(size);
        _lastSize = size;
        final blend = _mapBlend;
        final landmarks = _layoutLandmarks(rPix, center, size);

        return GestureDetector(
          onScaleStart: _onScaleStart,
          onScaleUpdate: (d) => _onScaleUpdate(d, size),
          onScaleEnd: _onScaleEnd,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _GlobePainter(
                  earth: _earth,
                  rotate: _rotate,
                  rotX: _rotX,
                  rotY: _rotY,
                  center: center,
                  rPix: rPix,
                  zoom: _zoom,
                  landmarks: landmarks,
                  focusIndex: widget.focusIndex,
                  mapBlend: blend,
                  mapCam: blend > 0 ? _buildCam(size) : null,
                  tileAt: _tileAt,
                  tileVersion: _tileVersion,
                  toTileCrs: _toTileCrs,
                  fromTileCrs: _fromTileCrs,
                  terrain: _terrain,
                  meshCache: _meshCache,
                  meshNs: _tileSource,
                ),
              ),
              for (final lm in landmarks) _landmarkWidget(lm),
              // 三维地形渲染启用的状态特征（tilt>15° 且 DEM 就绪；
              // 零尺寸不可见，供 widget 测试黑盒断言）
              if (blend > 0.5 && _tiltDeg > 15 && _terrain.loaded)
                const Positioned(
                  key: ValueKey('terrainMeshOn'),
                  left: 0,
                  top: 0,
                  child: SizedBox.shrink(),
                ),
              MapHeader(
                onClose: widget.onClose,
                subtitle: blend > 0.5
                    ? '街道级地图 · ${_tileSource == 0 ? 'OpenStreetMap' : '高德'}'
                    : '${photoGeo.length} 张照片 · 拖动旋转地球仪',
              ),
              if (blend > 0.5) _mapModeHint() else const MapHint(),
              if (blend > 0.3) _mapButtons(blend),
              if (_spaceMembers != null)
                LocationPhotoSpace(
                  photos: _spaceMembers!,
                  placeName: _spacePlaceName,
                  onClose: () => setState(() => _spaceMembers = null),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 地图模式底部提示（键名供 widget 测试黑盒断言地图模式）
  Widget _mapModeHint() {
    return Positioned(
      key: const ValueKey('mapModeHint'),
      left: 0,
      right: 0,
      bottom: 26,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(
            '拖动平移 · 双指继续放大 · 双击/长按浏览该地点',
            style: TextStyle(
                fontSize: 12, color: Colors.white.withValues(alpha: 0.7)),
          ),
        ),
      ),
    );
  }

  /// 右下角按钮簇（Google Earth 式圆形按钮 + 原切源胶囊）：自上而下为
  /// 2D/3D 俯仰切换、标准⇄卫星图层切换（仅高德源，OSM 无卫星样式）、
  /// 瓦片源切换。Positioned 底部锚定 + 切源胶囊在 Column 末位，保证切源
  /// 按钮屏幕位置不随上方按钮增减而移动。
  Widget _mapButtons(double blend) {
    return Positioned(
      right: 12,
      bottom: 68,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (blend > 0.5) ...[
            // 标签显示将切换到的目标模式（3D 视角显示 "2D"，反之 "3D"）
            _circleButton(
              key: const ValueKey('tiltToggle'),
              label: _tiltTo == 0.0 ? '3D' : '2D',
              onTap: _toggleTilt,
            ),
            if (_tileSource == 1) ...[
              const SizedBox(height: 10),
              _circleButton(
                key: const ValueKey('layerToggle'),
                label: _tileStyle == 7 ? '卫星' : '标准',
                fontSize: 12,
                onTap: () => setState(() {
                  _tileStyle = _tileStyle == 7 ? 6 : 7;
                  _evictStaleNamespaces();
                }),
              ),
            ],
            const SizedBox(height: 10),
          ],
          _sourcePill(),
        ],
      ),
    );
  }

  /// 圆形悬浮钮（Google Earth 风格）：44px 黑底圆 + 白描边
  Widget _circleButton({
    required Key key,
    required String label,
    required VoidCallback onTap,
    double fontSize = 14,
  }) {
    return GestureDetector(
      key: key,
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: 0.6),
          border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
        ),
        child: Text(
          label,
          style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: Colors.white),
        ),
      ),
    );
  }

  /// 瓦片源手动切换（OSM ⇄ 高德；连续失败也会自动切换）
  Widget _sourcePill() {
    return GestureDetector(
      key: const ValueKey('tileSourceToggle'),
      onTap: () => setState(() {
        _tileSource = 1 - _tileSource;
        _tileFailStreak = 0;
        _evictStaleNamespaces();
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
        ),
        child: Text(
          _tileSource == 0 ? 'OSM' : '高德',
          style: const TextStyle(fontSize: 11, color: Colors.white),
        ),
      ),
    );
  }

  /// 点按地名标签 → 直接飞往该地点（深处，自动进入地图模式）。
  /// 只在球体模式且标签可见（zoom>=1.6）时生效；取命中点最近的标签
  /// （文字画在锚点右侧，命中半径放宽到 64px 覆盖文字区）。
  void _tryFlyToPlaceLabel(Offset pos, Offset center, double rPix) {
    if (_mapBlend > 0.5 || _zoom < 1.6) return;
    PlaceLabel? best;
    var bestDist = 64.0;
    for (final label in placeLabels) {
      final r = _rotate(_latLngToUnit(label.point.lat, label.point.lng));
      if (r.z <= 0.03) continue;
      final persp = _camDist / (_camDist - r.z);
      final p = center + Offset(r.x * rPix * persp, -r.y * rPix * persp);
      final d = (p - pos).distance;
      if (d < bestDist) {
        bestDist = d;
        best = label;
      }
    }
    if (best != null) _flyTo(best.point, -1, select: false, zoom: 6.0);
  }

  /// 打开该地点（聚合组）照片的 3D 回忆空间式浏览器
  void _openPhotoSpace(_LandmarkLayout lm) {
    double lat = 0, lng = 0;
    for (final m in lm.members) {
      lat += m.point.lat;
      lng += m.point.lng;
    }
    lat /= lm.members.length;
    lng /= lm.members.length;
    // 最近的地名锚点（>1.5° 视为不匹配，交给组件兜底文案）
    var best = '';
    var bestDist = 1.5;
    for (final p in placeLabels) {
      final dLat = (p.point.lat - lat).abs();
      final dLng = (p.point.lng - lng).abs() * math.cos(lat * math.pi / 180);
      final d = math.sqrt(dLat * dLat + dLng * dLng);
      if (d < bestDist) {
        bestDist = d;
        best = p.name;
      }
    }
    setState(() {
      // 地图模式：真实地点网格组，全量浏览该地点全部照片；球体全景大组
      // （屏幕距离产物，非真实地点）等距抽样，避免一次塞数百张。
      _spaceMembers =
          _mapBlend > 0.5 ? lm.members : _sampleForSpace(lm.members);
      _spacePlaceName = best;
    });
  }

  /// 球体全景大聚合组等距抽样到 [_spaceMaxPhotos] 张（保留首尾），
  /// 避免上百张照片全塞进 LocationPhotoSpace 卡死
  static List<PhotoMapMarker> _sampleForSpace(List<PhotoMapMarker> members) {
    if (members.length <= _spaceMaxPhotos) return members;
    final n = members.length;
    return [
      for (var i = 0; i < _spaceMaxPhotos; i++)
        members[i * (n - 1) ~/ (_spaceMaxPhotos - 1)],
    ];
  }

  Widget _landmarkWidget(_LandmarkLayout lm) {
    final count = lm.members.length;
    final focused = lm.rep.storyIndex == widget.focusIndex;
    final opacity = lm.opacity;
    final scale =
        (lm.persp * 0.86 * (focused ? 1.18 : 1.0)).clamp(0.55, 1.65);
    final w = (focused ? 56.0 : 44.0) * scale;
    final h = w * 0.78;
    const pad = 8.0;
    return Positioned(
      left: lm.top.dx - w / 2 - pad,
      top: lm.top.dy - h - pad * 1.5,
      width: w + pad * 2,
      height: h + pad * 2,
      child: Opacity(
        opacity: opacity,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (count > 1) {
              // 聚合组：飞近放大散开，不改变故事选中
              double lat = 0, lng = 0;
              for (final m in lm.members) {
                lat += m.point.lat;
                lng += m.point.lng;
              }
              _flyTo(
                GeoPoint(lat / count, lng / count),
                lm.rep.storyIndex,
                select: false,
                zoom: (_zoom * 2.2).clamp(2.0, 8.0),
              );
            } else {
              // 非故事照片（storyIndex<0）：正常飞行，但不联动故事页选中
              _flyTo(lm.rep.point, lm.rep.storyIndex,
                  select: lm.rep.storyIndex >= 0);
            }
          },
          onDoubleTap: () => _openPhotoSpace(lm),
          onLongPress: () => _openPhotoSpace(lm),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: _LandmarkCard(
                thumbAsset: lm.rep.thumbAsset,
                focused: focused,
                count: count,
                width: w,
                height: h),
          ),
        ),
      ),
    );
  }
}

/// 地理网格聚合组：同一网格（≈2km，见 _clusterGridDeg）内的全部照片。
/// 只随 markers 重建，缩放/视角变化不影响分组，因此徽标计数稳定。
class _GeoGroup {
  const _GeoGroup({
    required this.members,
    required this.centroid,
    required this.baseRep,
  });

  final List<PhotoMapMarker> members; // 组内全部照片（>=1）
  final GeoPoint centroid; // 组锚点 = 成员质心
  final PhotoMapMarker baseRep; // 默认代表（故事镜头优先，否则首张）

  /// 展示代表：焦点 > 故事镜头 > 普通照片（与屏幕距离聚合同优先级）
  PhotoMapMarker repFor(int focusIndex) {
    if (focusIndex >= 0) {
      for (final m in members) {
        if (m.storyIndex == focusIndex) return m;
      }
    }
    return baseRep;
  }
}

/// 一组（或一张）地标牌的布局结果
class _LandmarkLayout {
  _LandmarkLayout({
    required this.members,
    required this.rep,
    required this.base,
    required this.top,
    required this.depth,
    required this.persp,
    required this.opacity,
  });

  final List<PhotoMapMarker> members; // 组内全部照片（>=1）
  PhotoMapMarker rep; // 展示用代表照片
  Offset base; // 基点（屏幕坐标，球面/地图插值后）
  Offset top; // 牌面锚点（屏幕坐标）
  final double depth; // 远近排序键（球面 z 与地图深度比插值）
  final double persp; // 牌面缩放系数
  final double opacity; // 牌面透明度（临边淡出 / 地图模式恒 1）
}

/// 立在地球上的照片地标牌（卡片部分，旗杆由画笔绘制）
class _LandmarkCard extends StatelessWidget {
  const _LandmarkCard({
    required this.thumbAsset,
    required this.focused,
    required this.count,
    required this.width,
    required this.height,
  });

  final String thumbAsset;
  final bool focused;
  final int count;
  final double width, height;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: focused ? const Color(0xFFFFD88A) : Colors.white,
              width: focused ? 2.2 : 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.55),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7),
            // 卡面最大 ~92 逻辑 px：按 96 解码避免 512px 原图全量上纹理
            //（每张解码内存 ~786KB → ~120KB，且全卡共享同一缓存条目）
            child: Image.asset(thumbAsset,
                fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: 96),
          ),
        ),
        if (count > 1)
          Positioned(
            top: -6,
            right: -6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: const Color(0xFFFFD88A),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: const Color(0xFF1A1408), width: 1),
              ),
              child: Text(
                '$count',
                style: const TextStyle(
                    fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A1408),
                        height: 1.1),
              ),
            ),
          ),
      ],
    );
  }
}

/// 一张瓦片的地形网格地面数据：17×17 顶点 ×（zInt 层世界 px x/y、
/// DEM 高程米、坡向明暗 0.55-1.0），每顶点 4 个 float。
/// 不随相机变，按瓦片 LRU 缓存；屏幕位置逐帧由当前相机投影重建。
class _TerrainMesh {
  const _TerrainMesh(this.data);

  final Float32List data;
}

/// 地球球体 + 地面平面地图 + 点云 + 旗杆的画笔
class _GlobePainter extends CustomPainter {
  _GlobePainter({
    required this.earth,
    required this.rotate,
    required this.rotX,
    required this.rotY,
    required this.center,
    required this.rPix,
    required this.zoom,
    required this.landmarks,
    required this.focusIndex,
    required this.mapBlend,
    required this.mapCam,
    required this.tileAt,
    required this.tileVersion,
    required this.toTileCrs,
    required this.fromTileCrs,
    required this.terrain,
    required this.meshCache,
    required this.meshNs,
  });

  final ui.Image? earth;
  final _V3 Function(_V3) rotate;

  /// 球体朝向（仅供 shouldRepaint 值比较，旋转本身经 rotate 闭包生效）
  final double rotX, rotY;
  final Offset center;
  final double rPix;
  final double zoom;
  final List<_LandmarkLayout> landmarks;
  final int focusIndex;

  /// 0 = 纯球体，1 = 纯地图（球体/大气/星空在 1 时跳过绘制）
  final double mapBlend;

  /// 地图模式相机（blend>0 时非空）
  final _MapCam? mapCam;

  /// 瓦片查询（未命中返回 null 并触发后台加载）
  final ui.Image? Function(int z, int x, int y) tileAt;

  /// 瓦片缓存版本号（缓存内容变化即 +1，供 shouldRepaint 值比较）
  final int tileVersion;

  /// 瓦片坐标系转换（高德源时 WGS-84 → GCJ-02）
  final GeoPoint Function(GeoPoint) toTileCrs;

  /// 反向转换（瓦片坐标系 → WGS-84），地形网格采样 DEM 用
  final GeoPoint Function(GeoPoint) fromTileCrs;

  /// 离线 DEM 地形数据（loaded=false 时 3D 倾斜退化为平面）
  final Terrain terrain;

  /// 地形网格地面数据缓存（State 持有，跨帧/跨画笔共享）
  final Map<String, _TerrainMesh> meshCache;

  /// 网格缓存命名空间（= 瓦片源编号；源不同 GCJ 采样不同，须区分）
  final int meshNs;

  static const double _camDist = 3.2;
  static const int _nx = 90, _ny = 45; // 球面网格细分

  // 预生成球面网格（单位坐标 + 纹理 UV，不随帧变化）
  static final List<_V3> _grid = [
    for (int iy = 0; iy <= _ny; iy++)
      for (int ix = 0; ix <= _nx; ix++)
        _GlobePainter._gridPoint(ix / _nx, iy / _ny),
  ];

  static _V3 _gridPoint(double u, double v) {
    final lambda = (u * 360 - 180) * math.pi / 180;
    final phi = (v * 180 - 90) * math.pi / 180;
    return _V3(math.cos(phi) * math.sin(lambda), math.sin(phi),
        math.cos(phi) * math.cos(lambda));
  }

  static double _gridU(int ix) => ix / _nx;
  static double _gridV(int iy) => 1 - iy / _ny;

  static final List<Offset> _stars = [
    for (int i = 0; i < 150; i++)
      Offset(_starRand(i * 2), _starRand(i * 2 + 1)),
  ];

  static double _starRand(int i) {
    // 确定性伪随机（避免每帧闪烁）
    final x = math.sin(i * 127.1 + 311.7) * 43758.5453;
    return x - x.floorToDouble();
  }

  @override
  void paint(Canvas canvas, Size size) {
    _paintBackground(canvas, size);
    if (mapBlend < 1) {
      _paintAtmosphere(canvas, behind: true);
      if (earth != null) _paintSphere(canvas);
      _paintPointCloud(canvas);
    }
    if (mapBlend > 0 && mapCam != null) {
      _paintMapPlane(canvas, size);
      _paintPointCloudMap(canvas);
    }
    _paintPoles(canvas);
    if (mapBlend < 1) _paintAtmosphere(canvas, behind: false);
    _paintPlaceLabels(canvas);
  }

  void _paintBackground(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.1),
          radius: 1.1,
          colors: const [Color(0xFF0B1322), Color(0xFF030509)],
        ).createShader(rect),
    );
    if (mapBlend >= 1) return; // 纯地图模式不画星空
    final starPaint = Paint();
    for (int i = 0; i < _stars.length; i++) {
      final s = _stars[i];
      final alpha = (0.10 + 0.45 * _starRand(i + 900)) * (1 - mapBlend);
      starPaint.color = Colors.white.withValues(alpha: alpha);
      canvas.drawCircle(
          Offset(s.dx * size.width, s.dy * size.height),
          0.5 + _starRand(i + 500) * 1.0,
          starPaint);
    }
  }

  void _paintAtmosphere(Canvas canvas, {required bool behind}) {
    final radius = rPix * 1.7;
    final paint = Paint()
      ..shader = RadialGradient(
        colors: behind
            ? const [Color(0x2E4E7DB8), Color(0x00000000)]
            : const [Color(0x00000000), Color(0x3D6FA8D9), Color(0x00000000)],
        stops: behind ? const [0.30, 1.0] : const [0.56, 0.62, 0.72],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    if (mapBlend > 0) {
      // 过渡带内随球体一起淡出
      canvas.saveLayer(Rect.fromCircle(center: center, radius: radius),
          Paint()..color = Colors.white.withValues(alpha: 1 - mapBlend));
      canvas.drawCircle(center, radius, paint);
      canvas.restore();
    } else {
      canvas.drawCircle(center, radius, paint);
    }
  }

  // 球体逐帧复用绘制缓冲（与地形路径同理：Vertices.raw 构造时原生侧
  // 即拷贝，可安全复用）。此前每帧新建 ~500KB typed lists + 变长 indices
  // List，60fps 自转/惯性期间 native peer 依赖 GC 回收、实测 Native Heap
  // 以 ~4.5MB/min 持续上爬；复用后球体路径只剩 Vertices/Shader 两个对象。
  static const int _sphereVerts = (_nx + 1) * (_ny + 1);
  static final Float32List _sPosBuf = Float32List(_sphereVerts * 2);
  static final Float32List _sUvBuf = Float32List(_sphereVerts * 2);
  static final Int32List _sColorBuf = Int32List(_sphereVerts);
  static final Float32List _sZsBuf = Float32List(_sphereVerts);
  static final Uint16List _sIndexBuf = Uint16List(_nx * _ny * 6);

  /// ImageShader 用的单位矩阵（此前每帧/每瓦片各新建一个 Matrix4）
  static final Float64List _identityM4 = Matrix4.identity().storage;

  void _paintSphere(Canvas canvas) {
    final cols = _nx + 1;
    final img = earth!;
    for (int i = 0; i < _sphereVerts; i++) {
      final r = rotate(_grid[i]);
      final persp = _camDist / (_camDist - r.z);
      _sPosBuf[i * 2] = center.dx + r.x * rPix * persp;
      _sPosBuf[i * 2 + 1] = center.dy - r.y * rPix * persp;
      // 注意：Vertices 的纹理坐标是着色器本地空间（图像像素），不是归一化 UV
      _sUvBuf[i * 2] = _gridU(i % cols) * img.width;
      _sUvBuf[i * 2 + 1] = _gridV(i ~/ cols) * img.height;
      _sZsBuf[i] = r.z;
      // 边缘变暗（limb darkening），背面更暗；过渡带内整体淡出
      final light = 0.20 + 0.80 * r.z.clamp(0.0, 1.0);
      final c = (255 * light).round();
      final a = (255 * (1 - mapBlend)).round();
      _sColorBuf[i] = (a << 24) | (c << 16) | (c << 8) | c;
    }

    var k = 0;
    for (int iy = 0; iy < _ny; iy++) {
      for (int ix = 0; ix < _nx; ix++) {
        final a = iy * cols + ix;
        final b = a + 1;
        final c = a + cols;
        final d = c + 1;
        // 背面剔除：四个顶点都在背面才跳过
        if (_sZsBuf[a] < -0.05 &&
            _sZsBuf[b] < -0.05 &&
            _sZsBuf[c] < -0.05 &&
            _sZsBuf[d] < -0.05) {
          continue;
        }
        _sIndexBuf[k++] = a;
        _sIndexBuf[k++] = c;
        _sIndexBuf[k++] = b;
        _sIndexBuf[k++] = b;
        _sIndexBuf[k++] = c;
        _sIndexBuf[k++] = d;
      }
    }

    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      _sPosBuf,
      textureCoordinates: _sUvBuf,
      colors: _sColorBuf,
      indices: Uint16List.sublistView(_sIndexBuf, 0, k),
    );
    final paint = Paint()
      ..shader =
          ui.ImageShader(img, ui.TileMode.clamp, ui.TileMode.clamp, _identityM4);
    canvas.drawVertices(vertices, BlendMode.modulate, paint);
  }

  void _paintPointCloud(Canvas canvas) {
    final near = <Offset>[];
    final far = <Offset>[];
    for (final g in photoGeo.values) {
      final r = rotate(_GlobePhotoMapState._latLngToUnit(g.lat, g.lng));
      if (r.z <= 0.02) continue;
      final persp = _camDist / (_camDist - r.z);
      final p = center + Offset(r.x * rPix * persp, -r.y * rPix * persp);
      (r.z > 0.55 ? near : far).add(p);
    }
    final fade = 1 - mapBlend;
    canvas.drawPoints(
        ui.PointMode.points,
        far,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.20 * fade)
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round);
    canvas.drawPoints(
        ui.PointMode.points,
        near,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.55 * fade)
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round);
  }

  /// 地面平面地图：可见瓦片逐张 drawVertices（单应透视四边形 +
  /// ImageShader，纹理坐标为图像像素空间）。未加载的瓦片画深色占位；
  /// 屏幕四角反投影求可见范围，按 floor(连续 z) 的整数层取瓦片。
  /// DEM 就绪且倾角 >15° 时走三维地形路径（_paintTileTerrain）：
  /// 逐瓦片 16×16 子网格按高程隆起，瓦片按中心深度远→近排序；
  /// 否则保持平面快速路径（2D 俯视/浅倾，位移不可见）。
  void _paintMapPlane(Canvas canvas, Size size) {
    final cam = mapCam!;
    final tg = cam.tileGround;
    final zInt = cam.zInt;
    final n = 1 << zInt;

    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final c in [
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ]) {
      final g = cam.unproject(c);
      minX = math.min(minX, g.dx);
      maxX = math.max(maxX, g.dx);
      minY = math.min(minY, g.dy);
      maxY = math.max(maxY, g.dy);
    }
    var x0 = (minX / tg).floor(), x1 = (maxX / tg).floor();
    var y0 = (minY / tg).floor(), y1 = (maxY / tg).floor();
    // 瓦片数兜底上限（地平线附近的极端情况）
    if (x1 - x0 > 24) {
      final mid = (x0 + x1) ~/ 2;
      x0 = mid - 12;
      x1 = x0 + 24;
    }
    if (y1 - y0 > 24) {
      final mid = (y0 + y1) ~/ 2;
      y0 = mid - 12;
      y1 = y0 + 24;
    }

    final alpha = (255 * mapBlend).round();
    final screenRect = Rect.fromLTRB(
        -320, -320, size.width + 320, size.height + 320);
    final placeholder = Paint()
      ..color = const Color(0xFF10161F).withValues(alpha: 0.92 * mapBlend);

    // 三维地形路径：DEM 就绪且倾角越过启用阈值（terrainHScale > 0）。
    // 近处高山在屏幕上可能压住远处瓦片，须按中心深度远→近画家算法排序。
    if (terrain.loaded && cam.terrainHScale > 0) {
      final jobs = <(int, int, double)>[];
      for (var ty = y0; ty <= y1; ty++) {
        if (ty < 0 || ty >= n) continue;
        for (var tx = x0; tx <= x1; tx++) {
          jobs.add((tx, ty, cam.depthOf((tx + 0.5) * tg, (ty + 0.5) * tg)));
        }
      }
      jobs.sort((a, b) => b.$3.compareTo(a.$3)); // 远（深度大）先画
      for (final (tx, ty, _) in jobs) {
        _paintTileTerrain(canvas, cam, zInt, tx, ty, alpha, screenRect);
      }
      return;
    }

    for (var ty = y0; ty <= y1; ty++) {
      if (ty < 0 || ty >= n) continue;
      for (var tx = x0; tx <= x1; tx++) {
        final p00 = cam.project(tx * tg, ty * tg);
        final p10 = cam.project((tx + 1) * tg, ty * tg);
        final p01 = cam.project(tx * tg, (ty + 1) * tg);
        final p11 = cam.project((tx + 1) * tg, (ty + 1) * tg);
        if (p00 == null || p10 == null || p01 == null || p11 == null) {
          continue; // 相机近裁剪面之后
        }
        if (!screenRect.contains(p00) &&
            !screenRect.contains(p10) &&
            !screenRect.contains(p01) &&
            !screenRect.contains(p11)) {
          continue;
        }
        final wx = tx % n;
        final img = tileAt(zInt, wx < 0 ? wx + n : wx, ty);
        if (img == null) {
          final path = Path()
            ..moveTo(p00.dx, p00.dy)
            ..lineTo(p10.dx, p10.dy)
            ..lineTo(p11.dx, p11.dy)
            ..lineTo(p01.dx, p01.dy)
            ..close();
          canvas.drawPath(path, placeholder);
          continue;
        }
        final positions = Float32List.fromList([
          p00.dx, p00.dy, //
          p10.dx, p10.dy,
          p01.dx, p01.dy,
          p11.dx, p11.dy,
        ]);
        // 注意：Vertices 的纹理坐标是着色器本地空间（图像像素），不是归一化 UV
        final uvs = Float32List.fromList([
          0, 0, //
          img.width.toDouble(), 0,
          0, img.height.toDouble(),
          img.width.toDouble(), img.height.toDouble(),
        ]);
        final colors = Int32List(4)
          ..fillRange(0, 4, (alpha << 24) | 0xFFFFFF);
        final vertices = ui.Vertices.raw(
          ui.VertexMode.triangles,
          positions,
          textureCoordinates: uvs,
          colors: colors,
          indices: Uint16List.fromList(const [0, 2, 1, 1, 2, 3]),
        );
        canvas.drawVertices(
          vertices,
          BlendMode.modulate,
          Paint()
            ..filterQuality = FilterQuality.medium
            ..shader = ui.ImageShader(
                img, ui.TileMode.clamp, ui.TileMode.clamp, _identityM4),
        );
      }
    }
  }

  // ---- 三维地形（Google Earth 式：真实山体隆起 + 纹理蒙皮 + 坡向明暗）----

  /// 每瓦片地形子网格细分（16×16 格 = 17×17 顶点 = 512 三角形）
  static const int _terrainSub = 16;
  static const int _terrainVerts = (_terrainSub + 1) * (_terrainSub + 1);

  /// 顶点纹理坐标比例（ix/sub, iy/sub），乘瓦片图像像素宽高得 UV
  static final Float32List _terrainUVFrac = Float32List.fromList([
    for (var iy = 0; iy <= _terrainSub; iy++)
      for (var ix = 0; ix <= _terrainSub; ix++) ...[
        ix / _terrainSub,
        iy / _terrainSub,
      ],
  ]);

  // 逐帧复用的绘制缓冲（Vertices.raw 构造时原生侧即拷贝，可安全复用）
  static final Float32List _posBuf = Float32List(_terrainVerts * 2);
  static final Float32List _uvBuf = Float32List(_terrainVerts * 2);
  static final Int32List _colorBuf = Int32List(_terrainVerts);
  static final Uint8List _validBuf = Uint8List(_terrainVerts);
  static final Uint16List _indexBuf =
      Uint16List(_terrainSub * _terrainSub * 6);

  /// 单张瓦片的三维地形绘制：顶点 = zInt 层墨卡托地面点（缓存）× 连续
  /// 缩放 + DEM 高程经 elevationToPx 抬高 → 当前相机投影；纹理坐标 =
  /// 瓦片像素坐标；顶点色 = 透明度 × 坡向明暗（modulate 到纹理/底色）。
  /// 近裁剪面后的顶点所在小格剔除；投影包围盒整体出屏也剔除。
  void _paintTileTerrain(Canvas canvas, _MapCam cam, int zInt, int tx,
      int ty, int alpha, Rect screenRect) {
    final mesh = _meshAt(zInt, tx, ty);
    final scale = math.pow(2.0, cam.z - zInt).toDouble();
    final data = mesh.data;
    var minSx = double.infinity, minSy = double.infinity;
    var maxSx = -double.infinity, maxSy = -double.infinity;
    for (var i = 0; i < _terrainVerts; i++) {
      final p = cam.project(data[i * 4] * scale, data[i * 4 + 1] * scale,
          cam.elevationToPx(data[i * 4 + 2]));
      if (p == null) {
        _validBuf[i] = 0;
        _posBuf[i * 2] = 0;
        _posBuf[i * 2 + 1] = 0;
      } else {
        _validBuf[i] = 1;
        _posBuf[i * 2] = p.dx;
        _posBuf[i * 2 + 1] = p.dy;
        if (p.dx < minSx) minSx = p.dx;
        if (p.dx > maxSx) maxSx = p.dx;
        if (p.dy < minSy) minSy = p.dy;
        if (p.dy > maxSy) maxSy = p.dy;
      }
    }
    // 地平线外/屏幕外剔除
    if (maxSx < screenRect.left ||
        minSx > screenRect.right ||
        maxSy < screenRect.top ||
        minSy > screenRect.bottom) {
      return;
    }
    // 行序 = 北→南（相机朝北，行序即大致远→近）；近裁剪小格跳过
    const sub = _terrainSub;
    const cols = sub + 1;
    var k = 0;
    for (var iy = 0; iy < sub; iy++) {
      for (var ix = 0; ix < sub; ix++) {
        final a = iy * cols + ix;
        final b = a + 1;
        final c = a + cols;
        final d = c + 1;
        if (_validBuf[a] == 0 ||
            _validBuf[b] == 0 ||
            _validBuf[c] == 0 ||
            _validBuf[d] == 0) {
          continue;
        }
        _indexBuf[k++] = a;
        _indexBuf[k++] = c;
        _indexBuf[k++] = b;
        _indexBuf[k++] = b;
        _indexBuf[k++] = c;
        _indexBuf[k++] = d;
      }
    }
    if (k == 0) return;
    for (var i = 0; i < _terrainVerts; i++) {
      final g = (data[i * 4 + 3] * 255).round().clamp(0, 255);
      _colorBuf[i] = (alpha << 24) | (g << 16) | (g << 8) | g;
    }
    final n = 1 << zInt;
    final wx = tx % n;
    final img = tileAt(zInt, wx < 0 ? wx + n : wx, ty);
    final Paint paint;
    Float32List? uvs;
    if (img == null) {
      // 未加载：深色 × 坡向明暗，山体轮廓在瓦片到达前已可辨
      paint = Paint()..color = const Color(0xFF10161F);
    } else {
      // 注意：Vertices 的纹理坐标是着色器本地空间（图像像素），不是归一化 UV
      for (var i = 0; i < _terrainVerts; i++) {
        _uvBuf[i * 2] = _terrainUVFrac[i * 2] * img.width;
        _uvBuf[i * 2 + 1] = _terrainUVFrac[i * 2 + 1] * img.height;
      }
      uvs = _uvBuf;
      paint = Paint()
        ..filterQuality = FilterQuality.medium
        ..shader = ui.ImageShader(
            img, ui.TileMode.clamp, ui.TileMode.clamp, _identityM4);
    }
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      _posBuf,
      textureCoordinates: uvs,
      colors: _colorBuf,
      indices: Uint16List.sublistView(_indexBuf, 0, k),
    );
    canvas.drawVertices(vertices, BlendMode.modulate, paint);
  }

  /// 地形网格地面数据（LRU 上限 120 张）：zInt 层世界 px、DEM 高程
  /// （米）、坡向明暗。只随瓦片变、不随相机变；屏幕位置逐帧投影重建。
  _TerrainMesh _meshAt(int zInt, int tx, int ty) {
    final key = '$meshNs/$zInt/$tx/$ty';
    final hit = meshCache.remove(key);
    if (hit != null) {
      meshCache[key] = hit; // LRU：重新插到尾部
      return hit;
    }
    const sub = _terrainSub;
    const cols = sub + 1;
    final data = Float32List(cols * cols * 4);
    for (var iy = 0; iy <= sub; iy++) {
      for (var ix = 0; ix <= sub; ix++) {
        final i = iy * cols + ix;
        // 顶点地面位置（zInt 层世界 px）→ 经纬 →（高德源时回 GCJ 偏移）
        // → WGS-84 DEM 双线性采样高程与坡向明暗
        final wx = (tx + ix / sub) * 256.0;
        final wy = (ty + iy / sub) * 256.0;
        final wgs =
            fromTileCrs(_MapCam.worldToLatLng(Offset(wx, wy), zInt.toDouble()));
        data[i * 4] = wx;
        data[i * 4 + 1] = wy;
        data[i * 4 + 2] = terrain.heightAt(wgs.lat, wgs.lng);
        data[i * 4 + 3] = terrain.shadeAt(wgs.lat, wgs.lng);
      }
    }
    final mesh = _TerrainMesh(data);
    meshCache[key] = mesh;
    while (meshCache.length > 120) {
      meshCache.remove(meshCache.keys.first);
    }
    return mesh;
  }

  /// 地图模式的 632 点云：lat/lng → 墨卡托 → 俯视投影（DEM 就绪时
  /// 锚定地形表面；倾角 <15° 时 elevationToPx 为 0 自动退化平面）
  void _paintPointCloudMap(Canvas canvas) {
    final cam = mapCam!;
    final pts = <Offset>[];
    for (final g in photoGeo.values) {
      final w = _MapCam.latLngToWorld(toTileCrs(g), cam.z);
      final hPx = cam.elevationToPx(terrain.heightAt(g.lat, g.lng));
      final p = cam.project(w.dx, w.dy, hPx);
      if (p != null) pts.add(p);
    }
    if (pts.isEmpty) return;
    canvas.drawPoints(
        ui.PointMode.points,
        pts,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.5 * mapBlend)
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round);
  }

  void _paintPoles(Canvas canvas) {
    for (final lm in landmarks) {
      final focused = lm.rep.storyIndex == focusIndex;
      final alpha = (0.20 + 0.75 * lm.depth).clamp(0.0, 1.0);
      final color = focused
          ? const Color(0xFFFFD88A).withValues(alpha: alpha)
          : Colors.white.withValues(alpha: alpha * 0.8);
      final paint = Paint()
        ..color = color
        ..strokeWidth = focused ? 2.2 : 1.4
        ..strokeCap = StrokeCap.round;
      // 旗杆：从球面基点指向牌面锚点（留 3px 间隙）
      final dir = (lm.top - lm.base);
      final len = dir.distance;
      if (len < 4) continue;
      final tip = lm.top - dir / len * 3;
      canvas.drawLine(lm.base, tip, paint);
      // 基点亮点
      canvas.drawCircle(
          lm.base, focused ? 3.2 : 2.4, Paint()..color = color);
    }
  }

  /// Google Earth 式地名标注（place_names.dart 的离线反地理编码数据）。
  /// zoom<1.6 不显示，1.6→2.4 透明度渐入；背面不画；近大远小随透视微调。
  /// 地图模式（blend>0.5）隐藏——瓦片自带道路/POI 标签。
  /// 仅绘制，不参与手势。
  void _paintPlaceLabels(Canvas canvas) {
    if (zoom < 1.6 || mapBlend > 0.5) return;
    final fade = ((zoom - 1.6) / 0.8).clamp(0.0, 1.0);
    for (final label in placeLabels) {
      final r = rotate(
          _GlobePhotoMapState._latLngToUnit(label.point.lat, label.point.lng));
      if (r.z <= 0.03) continue;
      final persp = _camDist / (_camDist - r.z);
      final p = center + Offset(r.x * rPix * persp, -r.y * rPix * persp);
      final alpha =
          fade * ((r.z - 0.03) / 0.25).clamp(0.0, 1.0);
      if (alpha <= 0.01) continue;
      final fontSize =
          12.5 * (0.85 + 0.3 * (persp - 1.0)).clamp(0.8, 1.15);

      // 锚点小圆点（白芯 + 深色描边）
      canvas.drawCircle(
          p,
          3.4,
          Paint()
            ..color = Colors.black.withValues(alpha: 0.4 * alpha)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2);
      canvas.drawCircle(
          p, 2.4, Paint()..color = Colors.white.withValues(alpha: 0.95 * alpha));

      // 白字 + 深色描边/光晕，放在锚点右侧、垂直居中
      const textStyle = TextStyle(fontWeight: FontWeight.w600, height: 1.15);
      final strokePainter = TextPainter(
        text: TextSpan(
          text: label.name,
          style: textStyle.copyWith(
            fontSize: fontSize,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeJoin = StrokeJoin.round
              ..strokeWidth = 2.8
              ..color = Colors.black.withValues(alpha: 0.85 * alpha),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final fillPainter = TextPainter(
        text: TextSpan(
          text: label.name,
          style: textStyle.copyWith(
            fontSize: fontSize,
            color: Colors.white.withValues(alpha: alpha),
            shadows: [
              Shadow(
                  color: Colors.black.withValues(alpha: 0.6 * alpha),
                  blurRadius: 6),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final textPos = p + Offset(7, -fillPainter.height / 2);
      strokePainter.paint(canvas, textPos);
      fillPainter.paint(canvas, textPos);
    }
  }

  @override
  bool shouldRepaint(_GlobePainter old) {
    // 值比较重绘：视觉输入全相同则跳过重绘（此前恒 true，静止时父级
    // 重建也会触发整屏 60fps 重绘）。瓦片/网格缓存变化经 tileVersion
    // 体现；landmarks 每帧重建，逐项比值（远廉价于一次重绘）。
    if (earth != old.earth ||
        rotX != old.rotX ||
        rotY != old.rotY ||
        zoom != old.zoom ||
        rPix != old.rPix ||
        center != old.center ||
        mapBlend != old.mapBlend ||
        focusIndex != old.focusIndex ||
        tileVersion != old.tileVersion ||
        meshNs != old.meshNs ||
        terrain.loaded != old.terrain.loaded ||
        landmarks.length != old.landmarks.length) {
      return true;
    }
    final a = mapCam, b = old.mapCam;
    if ((a == null) != (b == null)) return true;
    if (a != null &&
        (a.cx != b!.cx ||
            a.cy != b.cy ||
            a.z != b.z ||
            a.tiltRad != b.tiltRad ||
            a.hRef != b.hRef ||
            a.camH != b.camH ||
            a.screenCenter != b.screenCenter)) {
      return true;
    }
    for (var i = 0; i < landmarks.length; i++) {
      final l = landmarks[i], o = old.landmarks[i];
      if (l.base != o.base ||
          l.top != o.top ||
          l.depth != o.depth ||
          l.persp != o.persp ||
          l.opacity != o.opacity ||
          l.rep != o.rep ||
          l.members.length != o.members.length) {
        return true;
      }
    }
    return false;
  }
}
