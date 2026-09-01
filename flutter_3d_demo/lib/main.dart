import 'package:flutter/material.dart';

import 'pages/entry_page.dart';
import 'pages/generating_page.dart';
import 'pages/interactive_story_page.dart';
import 'player/story_player_page.dart';
import 'story/story_models.dart';
import 'widgets/phone_stage.dart';

const String _autostart =
    String.fromEnvironment('AUTOSTART', defaultValue: 'entry');
const String _startAtRaw =
    String.fromEnvironment('START_AT', defaultValue: '0');
final double _startAt = double.tryParse(_startAtRaw) ?? 0;

void main() {
  runApp(const Flutter3DDemoApp());
}

class Flutter3DDemoApp extends StatelessWidget {
  const Flutter3DDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '夸克相册 · 3D 回忆故事',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B6DFF),
          brightness: Brightness.dark,
        ),
      ),
      home: PhoneStage(child: _home()),
    );
  }

  Widget _home() {
    switch (_autostart) {
      case 'generating':
        return GeneratingPage(story: demoStory);
      case 'interactive':
        return InteractiveStoryPage(story: demoStory);
      case 'player':
        return StoryPlayerPage(story: demoStory, startAt: _startAt);
      default:
        return const MemoryEntryPage();
    }
  }
}
