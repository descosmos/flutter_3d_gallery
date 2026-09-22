import 'package:flutter/material.dart';

import '../gpu/globe_page.dart';
import '../story/photo_geo.dart';
import '../story/story_models.dart';
import 'photo_map_shared.dart';

/// 兼容照片地图入口，实际绘制由 Flutter GPU 的球体网格完成。
class GlobePhotoMap extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final selected = markers.where((m) => m.storyIndex == focusIndex);
    return GpuGlobePage(
      focus: selected.isEmpty ? const GeoPoint(43, 86) : selected.first.point,
      story: demoStory,
      onClose: onClose,
    );
  }
}
