import 'package:flutter/material.dart';

import '../gpu/story_scene.dart';
import '../story/story_models.dart';

class StoryScene extends StatelessWidget {
  const StoryScene({
    super.key,
    required this.story,
    required this.time,
    required this.parallax,
  });
  final StorySpec story;
  final double time;
  final Offset parallax;
  @override
  Widget build(BuildContext context) =>
      GpuStoryScene(story: story, time: time, parallax: parallax);
}
