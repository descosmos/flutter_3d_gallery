/// 离线 DEM 地形数据：开发期由 Terrarium/Mapzen z9 地形瓦片（免 key，
/// h = r*256+g+b/256-32768）重采样成规则经纬网格，打包进 assets，
/// 运行时不联网。供地图模式 3D 倾斜视角做三维地形（网格顶点抬高 +
/// 坡向明暗 + 地标锚定）。
///
/// 二进制格式（小端）：'TRN1' magic + i32 version + f64 minLng/minLat/
/// stepLng/stepLat + i32 cols/rows + int16[rows*cols] 高程（米，
/// row-major，row 0 = minLat 南，col 0 = minLng 西）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

class Terrain {
  Terrain();

  static const String assetPath = 'assets/terrain.bin';

  /// 坡向明暗用的平行光源：方位角 135°（东南来光 → 西北坡偏暗，增强
  /// 沟壑感）、高度角 40°。不追求物理精确，只做视觉浮雕。
  static const double _sunAz = 135 * math.pi / 180;
  static const double _sunAlt = 40 * math.pi / 180;

  double minLng = 0, minLat = 0, stepLng = 1, stepLat = 1;
  int cols = 0, rows = 0;
  Int16List? _elev;
  bool loaded = false;

  /// 从 assets 加载并解析；文件缺失/格式错误时保持 loaded=false，
  /// 地图退化为无地形的平面 3D（不影响其他功能）。
  Future<void> load() async {
    try {
      final data = await rootBundle.load(assetPath);
      final buf = data.buffer;
      final off = data.offsetInBytes;
      final len = data.lengthInBytes;
      final bd = ByteData.view(buf, off, len);
      // magic 'T' 'R' 'N' '1'
      if (len < 48 ||
          bd.getUint8(0) != 0x54 ||
          bd.getUint8(1) != 0x52 ||
          bd.getUint8(2) != 0x4E ||
          bd.getUint8(3) != 0x31 ||
          bd.getInt32(4, Endian.little) != 1) {
        return;
      }
      minLng = bd.getFloat64(8, Endian.little);
      minLat = bd.getFloat64(16, Endian.little);
      stepLng = bd.getFloat64(24, Endian.little);
      stepLat = bd.getFloat64(32, Endian.little);
      cols = bd.getInt32(40, Endian.little);
      rows = bd.getInt32(44, Endian.little);
      final count = cols * rows;
      if (cols <= 1 || rows <= 1 || (len - 48) ~/ 2 < count) return;
      _elev = buf.asInt16List(off + 48, count);
      loaded = true;
    } catch (_) {
      loaded = false;
    }
  }

  /// 双线性采样高程（米，WGS-84 经纬度）。坐标钳制到网格边缘
  /// （网格外沿用最外侧值，不出现断崖）。
  double heightAt(double lat, double lng) {
    final h = _elev;
    if (h == null) return 0;
    final fx = ((lng - minLng) / stepLng).clamp(0.0, cols - 1.000001);
    final fy = ((lat - minLat) / stepLat).clamp(0.0, rows - 1.000001);
    final x0 = fx.floor(), y0 = fy.floor();
    final tx = fx - x0, ty = fy - y0;
    final i = y0 * cols + x0;
    final h00 = h[i], h10 = h[i + 1], h01 = h[i + cols], h11 = h[i + cols + 1];
    final top = h00 + (h10 - h00) * tx;
    final bot = h01 + (h11 - h01) * tx;
    return top + (bot - top) * ty;
  }

  /// 坡向明暗系数（0.55 暗 ～ 1.0 亮）：DEM 梯度求法线，与东南来光
  /// 点积。梯度采样间隔取一个网格步长（约 800m，宏观山体浮雕）。
  double shadeAt(double lat, double lng) {
    final latRad = lat * math.pi / 180;
    final cellE = stepLng * 111320 * math.cos(latRad); // 东向步长（米）
    final cellN = stepLat * 111320; // 北向步长（米）
    final dzdx = (heightAt(lat, lng + stepLng) - heightAt(lat, lng - stepLng)) /
        (2 * cellE);
    final dzdy = (heightAt(lat + stepLat, lng) - heightAt(lat - stepLat, lng)) /
        (2 * cellN);
    final invLen = 1 / math.sqrt(dzdx * dzdx + dzdy * dzdy + 1);
    // 法线 (-dzdx, -dzdy, 1) · 光源方向（东、北、天）
    final lx = math.sin(_sunAz) * math.cos(_sunAlt);
    final ly = math.cos(_sunAz) * math.cos(_sunAlt);
    final lz = math.sin(_sunAlt);
    final s = (-dzdx * invLen) * lx + (-dzdy * invLen) * ly + invLen * lz;
    return 1.0 - (1 - s.clamp(0.0, 1.0)) * 0.45;
  }
}
