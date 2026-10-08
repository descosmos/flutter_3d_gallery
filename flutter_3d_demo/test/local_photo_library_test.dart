import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_3d_demo/photos/local_photo_library.dart';
import 'package:flutter_3d_demo/photos/photo_source.dart';
import 'package:flutter_3d_demo/story/photo_geo.dart';
import 'package:flutter_3d_demo/story/story_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalPhotoLibrary library;
  late File valid, unlocated, broken;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('travel_library_test_');
    valid = await File('assets/photos/IMG_20240503_180134.jpg')
        .copy('${directory.path}/original.jpg');
    unlocated = await File('assets/photos/IMG_20240504_154139.jpg')
        .copy('${directory.path}/unlocated.jpg');
    broken = await File('${directory.path}/broken.jpg')
        .writeAsString('not an image');
    library = LocalPhotoLibrary(
      directory: Directory('${directory.path}/library'),
      metadataReader: (path) async => path == unlocated.path
          ? null
          : (
              point: const GeoPoint(-33.86, 151.2),
              takenAt: '2026-09-22T10:30:00',
            ),
    );
    await library.load();
  });
  tearDown(() async {
    library.dispose();
    await directory.delete(recursive: true);
  });

  test('只导入有 GPS 且可解码的图片；重复导入去重，原图不变', () async {
    final original = await valid.readAsBytes();
    await library.importPaths([
      valid.path,
      unlocated.path,
      broken.path,
      valid.path,
    ]);
    expect(library.error, isNull);
    expect(library.photos, hasLength(1));
    expect(library.notice, contains('跳过 1 张无位置信息'));
    expect(library.notice, contains('1 张读取失败'));
    expect(library.photos.single.point.lat, -33.86);
    expect(File(library.photos.single.path).existsSync(), isTrue);
    expect(
      File(photoThumbnail(library.photos.single.path)).existsSync(),
      isTrue,
    );
    expect(await valid.readAsBytes(), original);
  });

  test('全部无位置时两种视图均无照片可选', () async {
    await library.importPaths([unlocated.path]);
    expect(library.photos, isEmpty);
    expect(library.selected, isEmpty);
    expect(() => storyFromPhotos(library.selected), throwsArgumentError);
  });

  test('中断后的导入恢复，损坏的本地副本可通过重选原图修复', () async {
    final root = Directory('${directory.path}/library');
    await File('${root.path}/pending.json')
        .writeAsString(jsonEncode([valid.path]));
    await library.load();
    expect(library.photos, hasLength(1));
    final thumb = File(photoThumbnail(library.photos.single.path));
    await thumb.delete();
    await library.load();
    expect(library.photos, isEmpty);
    await library.importPaths([valid.path]);
    expect(library.photos, hasLength(1));
    expect(thumb.existsSync(), isTrue);
  });

  test('重启恢复照片与选择，移除副本不删除原图', () async {
    await library.importPaths([valid.path]);
    final id = library.selected.single.id;
    await library.select({});
    final reopened = LocalPhotoLibrary(
      directory: Directory('${directory.path}/library'),
    );
    await reopened.load();
    expect(reopened.photos, hasLength(1));
    expect(reopened.selected, isEmpty);
    await reopened.select({id});
    expect(reopened.selected, hasLength(1));
    final path = reopened.selected.single.path;
    await reopened.removeSelected();
    expect(reopened.photos, isEmpty);
    expect(File(path).existsSync(), isFalse);
    expect(valid.existsSync(), isTrue);
    reopened.dispose();
  });

  test('单张与多日照片全部进入空间与地球，示例数据不混入', () {
    LocalPhoto photo(String id, String date) => LocalPhoto(
      id: id,
      path: '/trip/$id/photo.png',
      name: id,
      point: const GeoPoint(0, 0),
      selected: true,
      takenAt: date,
    );
    final first = photo('a', '2026-09-22');
    final single = storyFromPhotos([first]);
    expect(single.spaceChapterCount, 1);
    expect(single.totalShots, 1);
    final story = storyFromPhotos([
      first,
      photo('b', '2026-09-23'),
      photo('c', '2026-09-23'),
    ]);
    expect(story.spaceChapterCount, 2);
    expect(
      story.chapters.take(story.spaceChapterCount).expand((c) => c.shots),
      hasLength(3),
    );
    expect(story.mapPhotos!.keys, [
      '/trip/a/photo.png',
      '/trip/b/photo.png',
      '/trip/c/photo.png',
    ]);
    expect(demoStory.mapPhotos, isNull);
    expect(demoStory.spaceChapterCount, demoStory.chapters.length - 1);
    expect(validPhotoLocation(const GeoPoint(0, 0)), isTrue);
    expect(validPhotoLocation(const GeoPoint(90.1, 0)), isFalse);
  });
}
