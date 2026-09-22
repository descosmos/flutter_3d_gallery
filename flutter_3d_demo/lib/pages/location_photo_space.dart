import 'package:flutter/material.dart';

import '../gpu/photo_space_page.dart';
import '../story/story_models.dart';
import 'photo_map_shared.dart';

class LocationPhotoSpace extends StatelessWidget {
  const LocationPhotoSpace({
    super.key,
    required this.photos,
    required this.placeName,
    required this.onClose,
  }) : assert(photos.length >= 1);
  final List<PhotoMapMarker> photos;
  final String placeName;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: GpuPhotoSpacePage(
      story: demoStory,
      photos: photos,
      placeName: placeName,
      onClose: onClose,
    ),
  );
}
