import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_3d_demo/story/photo_geo.dart';
import 'package:flutter_3d_demo/story/story_models.dart';

/// 故事时间线核心逻辑验证。
void main() {
  test('故事结构满足验收：≥4 章节、≥20 镜头、45-90 秒', () {
    expect(demoStory.chapters.length, greaterThanOrEqualTo(4));
    expect(demoStory.totalShots, greaterThanOrEqualTo(20));
    expect(demoStory.totalDuration, greaterThanOrEqualTo(45));
    expect(demoStory.totalDuration, lessThanOrEqualTo(90));
  });

  test('locate 定位各章节边界正确', () {
    final starts = demoStory.chapterStarts;
    expect(starts.first, 0);
    // 每个章节起点应定位到该章节的第一个镜头
    for (int i = 0; i < starts.length; i++) {
      final loc = demoStory.locate(starts[i] + 0.001);
      expect(loc.chapterIndex, i);
      expect(loc.shotIndex, 0);
    }
    // 结尾前落在最后一个章节
    final last = demoStory.locate(demoStory.totalDuration - 0.01);
    expect(last.chapterIndex, demoStory.chapters.length - 1);
  });

  test('所有镜头引用的时间合计等于总时长', () {
    final sum = demoStory.chapters
        .expand((c) => c.shots)
        .fold<double>(0, (a, s) => a + s.duration);
    expect(sum, closeTo(demoStory.totalDuration, 0.001));
  });

  test('镜头模板覆盖：至少三类可见空间效果', () {
    final templates = demoStory.chapters
        .expand((c) => c.shots)
        .map((s) => s.template)
        .toSet();
    // 深度推进、前后景视差、空间卡片转场
    expect(templates.contains(ShotTemplate.dollyIn), isTrue);
    expect(templates.contains(ShotTemplate.parallaxPan), isTrue);
    expect(templates.contains(ShotTemplate.cardSpace), isTrue);
  });

  test('故事镜头的照片都有 GPS 坐标（含插值）', () {
    for (final chapter in demoStory.chapters) {
      for (final shot in chapter.shots) {
        final thumb = 'assets/thumbs/${shot.asset.split('/').last}';
        expect(photoGeo.containsKey(thumb), isTrue, reason: shot.asset);
      }
    }
  });

  test('GPS 数据完整：全部照片有合法坐标', () {
    expect(photoGeo.length, 632);
    for (final entry in photoGeo.entries) {
      expect(entry.value.lat, inInclusiveRange(-90.0, 90.0), reason: entry.key);
      expect(entry.value.lng, inInclusiveRange(-180.0, 180.0),
          reason: entry.key);
    }
  });
}
