// 真机帧耗时采集入口；普通 lib/main.dart 构建不包含此探针。
// flutter build apk --release -t tool/frame_probe.dart --target-platform android-arm64
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:flutter_3d_demo/main.dart' as app;
import 'package:flutter_3d_demo/gpu/globe_page.dart';
import 'package:flutter_3d_demo/gpu/terrain_page.dart';
import 'package:flutter_3d_demo/gpu/photo_clusters.dart';
import 'package:flutter_3d_demo/pages/interactive_story_page.dart';
import 'package:flutter_3d_demo/pages/location_photo_space.dart';
import 'package:flutter_3d_demo/pages/photo_map_shared.dart';
import 'package:flutter_3d_demo/player/story_player_page.dart';
import 'package:flutter_3d_demo/story/photo_geo.dart';
import 'package:flutter_3d_demo/story/story_models.dart';
import 'package:flutter_3d_demo/widgets/phone_stage.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized().addTimingsCallback((frames) {
    for (final frame in frames) {
      // 每帧一行避免 logcat 的单行长度上限；单位均为微秒。
      // ignore: avoid_print
      print(
        'GALLERY_FRAME ${jsonEncode([frame.timestampInMicroseconds(FramePhase.vsyncStart), frame.buildDuration.inMicroseconds, frame.rasterDuration.inMicroseconds, frame.totalSpan.inMicroseconds])}',
      );
    }
  });
  // 仅探针入口支持 ADB --es route，便于同一 APK 重复相同场景。
  final route = PlatformDispatcher.instance.defaultRouteName;
  Widget? page;
  if (route == '/probe/interactive') {
    page = InteractiveStoryPage(story: demoStory);
  } else if (route.startsWith('/probe/globe')) {
    final distance = double.tryParse(route.split('/').last) ?? 12;
    final focus = distance < 4
        ? photoClusterRoots().reduce((a, b) => a.count > b.count ? a : b).center
        : const GeoPoint(44.6, 80.8);
    page = GpuGlobePage(
      focus: focus,
      story: demoStory,
      initialDistance: distance,
    );
  } else if (route.startsWith('/probe/terrain')) {
    final distance = double.tryParse(route.split('/').last) ?? 17;
    final focus =
        photoGeo['assets/thumbs/${demoStory.coverAsset.split('/').last}'] ??
        const GeoPoint(44.6, 81.2);
    page = GpuTerrainPage(
      focus: focus,
      story: demoStory,
      initialDistance: distance,
    );
  } else if (route == '/probe/location') {
    final groups = <(int, int), List<PhotoMapMarker>>{};
    for (final entry in photoGeo.entries) {
      final point = entry.value;
      (groups[((point.lat / 0.02).floor(), (point.lng / 0.02).floor())] ??= [])
          .add(
            PhotoMapMarker(storyIndex: -1, thumbAsset: entry.key, point: point),
          );
    }
    final photos = groups.values.reduce((a, b) => a.length >= b.length ? a : b);
    page = Scaffold(
      body: Stack(
        children: [
          LocationPhotoSpace(photos: photos, placeName: '地点照片', onClose: () {}),
        ],
      ),
    );
  } else if (route.startsWith('/probe/player')) {
    page = StoryPlayerPage(
      story: demoStory,
      startAt: double.tryParse(route.split('/').last) ?? 0,
    );
  }
  if (page == null) {
    app.main();
  } else {
    runApp(
      MaterialApp(
        initialRoute: '/',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF3B6DFF),
            brightness: Brightness.dark,
          ),
        ),
        home: PhoneStage(child: page),
      ),
    );
  }
}
