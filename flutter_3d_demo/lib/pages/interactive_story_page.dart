import 'package:flutter/material.dart';

import '../gpu/photo_space_page.dart';
import '../story/story_models.dart';

/// 交互入口：由 Flutter GPU 绘制真实三维照片场景。
class InteractiveStoryPage extends StatelessWidget {
  const InteractiveStoryPage({super.key, required this.story});
  final StorySpec story;
  @override
  Widget build(BuildContext context) => GpuPhotoSpacePage(story: story);
}
