// 仅性能诊断入口：真实 profile GPU 渲染，提供受控导航和缓存观测。
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_3d_demo/gpu/globe_page.dart';
import 'package:flutter_3d_demo/gpu/photo_clusters.dart';
import 'package:flutter_3d_demo/gpu/photo_space_page.dart';
import 'package:flutter_3d_demo/story/story_models.dart';

import 'frame_probe.dart' as probe;

Iterable<Element> elements(Element root) sync* {
  yield root;
  final children = <Element>[];
  root.visitChildElements(children.add);
  for (final child in children) {
    yield* elements(child);
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  developer.registerExtension('ext.gallery.perf', (method, parameters) async {
    final tree = elements(WidgetsBinding.instance.rootElement!).toList();
    final navigator = tree
        .whereType<StatefulElement>()
        .map((e) => e.state)
        .whereType<NavigatorState>()
        .first;
    final action = parameters['action'] ?? 'stats';
    if (action == 'pop') {
      if (navigator.canPop()) navigator.pop();
    } else if (action == 'reset') {
      navigator.popUntil((route) => route.isFirst);
    } else if (action == 'memory' || action == 'globe' || action == 'near') {
      final center = photoClusterRoots()
          .reduce((a, b) => a.count > b.count ? a : b)
          .center;
      navigator.push(
        MaterialPageRoute<void>(
          settings: RouteSettings(name: 'perf/$action'),
          builder: (_) => action == 'memory'
              ? GpuPhotoSpacePage(story: demoStory)
              : GpuGlobePage(
                  focus: center,
                  story: demoStory,
                  initialDistance: action == 'near' ? 2.012 : 12,
                ),
        ),
      );
    }
    final scenes = <Map<String, Object?>>[];
    for (final element in tree) {
      final view = element.widget;
      if (view is! fs.SceneView || view.scene == null) continue;
      final root = view.scene!.root;
      int nodes = 0, mapTiles = 0;
      void visit(fs.Node node) {
        nodes++;
        if (node.name.startsWith('globe-tile:')) mapTiles++;
        for (final child in node.children) {
          visit(child);
        }
      }

      visit(root);
      final route = ModalRoute.of(element);
      scenes.add({
        'route': route?.settings.name,
        'current': route?.isCurrent,
        'nodes': nodes,
        'map_tiles': mapTiles,
        'render_scale': view.scene!.renderScale,
      });
    }
    final cache = PaintingBinding.instance.imageCache;
    return developer.ServiceExtensionResponse.result(
      jsonEncode({
        'action': action,
        'rss_bytes': ProcessInfo.currentRss,
        'max_rss_bytes': ProcessInfo.maxRss,
        'image_cache_bytes': cache.currentSizeBytes,
        'image_cache_entries': cache.currentSize,
        'image_live': cache.liveImageCount,
        'image_pending': cache.pendingImageCount,
        'shared_cache': [
          for (final category in fs.takeMemoryReport().categories)
            {
              'name': category.name,
              'bytes': category.bytes,
              'count': category.count,
            },
        ],
        'scenes': scenes,
      }),
    );
  });
  probe.main();
}
