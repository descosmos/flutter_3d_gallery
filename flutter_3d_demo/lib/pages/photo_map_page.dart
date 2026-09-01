// 3D 照片地图入口：全平台统一的自绘 3D 地球仪
// （纹理球体 + 立在球面上的照片地标牌，见 photo_map_globe.dart）。
import 'package:flutter/material.dart';

import 'photo_map_globe.dart';
import 'photo_map_shared.dart';

export 'photo_map_shared.dart' show PhotoMapMarker;

class PhotoMapView extends StatelessWidget {
  const PhotoMapView({
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
  Widget build(BuildContext context) {
    return GlobePhotoMap(
      markers: markers,
      focusIndex: focusIndex,
      onSelectStory: onSelectStory,
      onClose: onClose,
    );
  }
}
