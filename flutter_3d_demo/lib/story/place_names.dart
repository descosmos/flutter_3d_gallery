/// 地球仪地点标签数据（Google Earth 式地名标注）。
///
/// 生成方式（2026-08-27，开发期离线生成后固化为常量，运行时不联网）：
/// 1. 锚点：demoStory 22 个地标牌的 GPS（见 photo_geo.dart）按 0.35°
///    质心聚类得到 8 个锚点（聚类脚本见会话记录，锚点=簇内成员均值）。
/// 2. 地名：对每个锚点请求 Nominatim 反地理编码
///    `https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=..&lon=..&zoom=..&accept-language=zh`
///    （自定义 UA，请求间隔 ≥1s），取 address 中最具体且不重名的
///    村/镇/市级字段，未人工杜撰；重名锚点改用更高 zoom 的村级结果。
/// 每条注释给出 Nominatim 原始 address 依据。
library;

import 'photo_geo.dart';

/// 一个地名标注：球面锚点 + 中文名
class PlaceLabel {
  const PlaceLabel(this.point, this.name);

  final GeoPoint point;
  final String name;
}

/// 8 个地点标签，按地标牌数量从多到少排列。
const placeLabels = <PlaceLabel>[
  // 6 张（赛里木湖沿岸，0509 全天）。zoom=10 返回：
  // {county: 博乐市, region: 博尔塔拉蒙古自治州, state: 新疆维吾尔自治区}
  PlaceLabel(GeoPoint(44.58954, 81.32697), '博乐市'),
  // 4 张（0504 下午）。zoom=10 返回：
  // {town: 解特阿热勒镇, county: 福海县, region: 阿勒泰地区}
  PlaceLabel(GeoPoint(47.40137, 87.57095), '解特阿热勒镇'),
  // 3 张（0507 上午，喀纳斯景区）。zoom=14 返回：
  // {village: 禾木村, city: 禾木哈纳斯蒙古民族乡, county: 布尔津县}
  PlaceLabel(GeoPoint(48.57244, 87.45090), '禾木村'),
  // 3 张（0505 上午，布尔津以南）。zoom=10 返回：
  // {city: 窝依莫克镇, county: 布尔津县, region: 阿勒泰地区}
  PlaceLabel(GeoPoint(48.34451, 87.13465), '窝依莫克镇'),
  // 2 张（0504 傍晚+深夜）。zoom=10 与窝依莫克镇重名，改 zoom=13：
  // {village: 托库木特村, city: 窝依莫克镇, county: 布尔津县}
  PlaceLabel(GeoPoint(47.76856, 86.77496), '托库木特村'),
  // 2 张（0507 深夜，魔鬼城一带）。zoom=10 返回：
  // {town: 乌尔禾镇, district: 乌尔禾区, city: 克拉玛依市}
  PlaceLabel(GeoPoint(46.11442, 85.66038), '乌尔禾镇'),
  // 1 张（0503 傍晚抵达）。zoom=10 返回：
  // {suburb: 振安街街道, district: 水磨沟区, city: 乌鲁木齐市}
  PlaceLabel(GeoPoint(43.89866, 87.64283), '乌鲁木齐市'),
  // 1 张（0505 下午，喀纳斯湖北）。zoom=10 与禾木重名，改 zoom=14：
  // {hamlet: 吐鲁克, city: 禾木哈纳斯蒙古民族乡, county: 布尔津县}
  PlaceLabel(GeoPoint(48.70902, 87.02369), '吐鲁克'),
];
