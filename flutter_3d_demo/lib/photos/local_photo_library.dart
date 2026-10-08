import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:native_exif/native_exif.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../story/photo_geo.dart';
import '../story/story_models.dart';

typedef PhotoMetadata = ({GeoPoint point, String? takenAt});

class LocalPhoto {
  const LocalPhoto({
    required this.id,
    required this.path,
    required this.name,
    required this.point,
    required this.selected,
    this.takenAt,
    this.portrait = false,
  });
  final String id, path, name;
  final GeoPoint point;
  final bool selected, portrait;
  final String? takenAt;
  String get day => takenAt != null && takenAt!.length >= 10
      ? takenAt!.substring(0, 10).replaceAll(':', '.').replaceAll('-', '.')
      : '旅行照片';

  static LocalPhoto? fromJson(String root, Map<String, dynamic> json) {
    final lat = (json['lat'] as num?)?.toDouble();
    final lng = (json['lng'] as num?)?.toDouble();
    if (lat == null || lng == null || !validPhotoLocation(GeoPoint(lat, lng))) {
      return null;
    }
    return LocalPhoto(
      id: json['id'] as String,
      path: '$root/${json['id']}/photo.png',
      name: json['name'] as String,
      point: GeoPoint(lat, lng),
      selected: json['selected'] as bool? ?? true,
      takenAt: json['takenAt'] as String?,
      portrait: (json['height'] as num) > (json['width'] as num),
    );
  }
}

bool validPhotoLocation(GeoPoint p) =>
    p.lat.isFinite && p.lng.isFinite && p.lat.abs() <= 90 && p.lng.abs() <= 180;

StorySpec storyFromPhotos(List<LocalPhoto> photos) {
  if (photos.isEmpty) throw ArgumentError('请先选择带位置的照片');
  final groups = <String, List<ShotSpec>>{};
  for (final photo in photos) {
    (groups[photo.day] ??= []).add(
      ShotSpec(
        asset: photo.path,
        template: ShotTemplate.dollyIn,
        duration: 4,
        portrait: photo.portrait,
      ),
    );
  }
  return StorySpec(
    title: '我的旅行',
    dateLabel: groups.keys.join(' · '),
    photoCount: photos.length,
    coverAsset: photos.first.path,
    chapters: [
      for (final group in groups.entries)
        ChapterSpec(title: group.key, shots: group.value),
    ],
    hasClosingChapter: false,
    mapPhotos: {for (final photo in photos) photo.path: photo.point},
  );
}

Future<PhotoMetadata?> readPhotoMetadata(String path) async {
  final exif = await Exif.fromPath(path);
  try {
    final gps = await exif.getLatLong();
    if (gps == null) return null;
    final point = GeoPoint(gps.latitude, gps.longitude);
    if (!validPhotoLocation(point)) return null;
    return (
      point: point,
      takenAt: (await exif.getOriginalDate())?.toIso8601String(),
    );
  } finally {
    await exif.close();
  }
}

/// Flutter owns selection, EXIF filtering, image preparation and durable storage.
class LocalPhotoLibrary extends ChangeNotifier {
  LocalPhotoLibrary({
    Directory? directory,
    Future<PhotoMetadata?> Function(String)? metadataReader,
  }) : _root = directory,
       _metadataReader = metadataReader ?? readPhotoMetadata;
  Directory? _root;
  final Future<PhotoMetadata?> Function(String) _metadataReader;
  List<Map<String, dynamic>> _records = [];
  List<LocalPhoto> photos = [];
  bool busy = false, importing = false, _disposed = false;
  String? error, notice;
  (int, int)? progress;
  List<LocalPhoto> get selected => photos.where((p) => p.selected).toList();

  Future<void> _initialize() async {
    _root ??= Directory(
      '${(await getApplicationSupportDirectory()).path}/travel_photos',
    );
    await _root!.create(recursive: true);
    // Re-read before mutations so a failed initial load never overwrites a library.
    if (await _manifest.exists()) {
      _records = (jsonDecode(await _manifest.readAsString()) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
  }

  File get _manifest => File('${_root!.path}/library.json');
  File get _pending => File('${_root!.path}/pending.json');

  Future<void> load() => _run(() async {
    await _initialize();
    // Imports already handed back by the picker can resume after process death.
    if (await _pending.exists()) {
      await _import(
        (jsonDecode(await _pending.readAsString()) as List).cast<String>(),
      );
    }
    await _refresh();
  });

  Future<void> pick() => _run(() async {
    await _initialize();
    if (Platform.isAndroid) await Permission.accessMediaLocation.request();
    // Document selection with uncompressed originals preserves EXIF GPS.
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'jpg',
        'jpeg',
        'heic',
        'heif',
        'png',
        'webp',
        'tif',
        'tiff',
      ],
    );
    if (files.isEmpty) return;
    final paths = files.map((f) => f.path).whereType<String>().toList();
    if (paths.isEmpty) throw const FileSystemException('无法读取所选照片');
    await _writeJson(_pending, paths);
    await _import(paths);
  }, isImport: true);

  /// The same import pipeline is also exercised by on-device integration tests.
  Future<void> importPaths(List<String> paths) => _run(() async {
    await _initialize();
    await _writeJson(_pending, paths);
    await _import(paths);
  }, isImport: true);

  Future<void> _import(List<String> paths) async {
    int imported = 0, skipped = 0, failed = 0;
    for (int i = 0; i < paths.length; i++) {
      progress = (i + 1, paths.length);
      _notify();
      try {
        final metadata = await _metadataReader(paths[i]);
        if (metadata == null || !validPhotoLocation(metadata.point)) {
          skipped++;
        } else {
          final source = File(paths[i]);
          final id = (await sha256.bind(source.openRead()).first).toString();
          final existing = _records.indexWhere((r) => r['id'] == id);
          if (existing >= 0) {
            if (!await File('${_root!.path}/$id/photo.png').exists() ||
                !await File('${_root!.path}/$id/thumb.png').exists()) {
              await _preparePhoto(
                source.path,
                await Directory('${_root!.path}/$id').create(recursive: true),
              );
            }
            _records[existing]['selected'] = true;
          } else {
            final directory = await Directory('${_root!.path}/$id')
                .create(recursive: true);
            final size = await _preparePhoto(source.path, directory);
            _records.add({
              'id': id,
              'name': source.uri.pathSegments.last,
              'lat': metadata.point.lat,
              'lng': metadata.point.lng,
              'takenAt': metadata.takenAt,
              'width': size.width,
              'height': size.height,
              'selected': true,
            });
            imported++;
          }
        }
      } catch (_) {
        failed++;
      }
      // Atomic, per-photo commits retain completed work even if import is interrupted.
      await _writeJson(_manifest, _records);
      await _writeJson(_pending, paths.sublist(i + 1));
    }
    await _pending.delete();
    await _refresh();
    notice = [
      if (imported > 0) '已导入 $imported 张照片',
      if (skipped > 0) '已跳过 $skipped 张无位置信息的照片',
      if (failed > 0) '$failed 张读取失败，可重新选择',
      if (imported == 0 && skipped == 0 && failed == 0) '所选照片已在相册中',
    ].join('；');
  }

  Future<void> select(Set<String> ids) => _run(() async {
    final updated = [
      for (final record in _records)
        {...record, 'selected': ids.contains(record['id'])},
    ];
    await _writeJson(_manifest, updated);
    _records = updated;
    await _refresh();
  });

  Future<void> removeSelected() => _run(() async {
    final ids = selected.map((p) => p.id).toSet();
    final updated = _records.where((r) => !ids.contains(r['id'])).toList();
    await _writeJson(_manifest, updated);
    _records = updated;
    await _refresh();
    for (final id in ids) {
      final directory = Directory('${_root!.path}/$id');
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });

  Future<void> _refresh() async {
    final available = <LocalPhoto>[];
    for (final record in _records) {
      final photo = LocalPhoto.fromJson(_root!.path, record);
      if (photo != null &&
          await File(photo.path).exists() &&
          await File('${_root!.path}/${photo.id}/thumb.png').exists()) {
        available.add(photo);
      }
    }
    available.sort((a, b) => (a.takenAt ?? '').compareTo(b.takenAt ?? ''));
    photos = available;
  }

  Future<void> _run(
    Future<void> Function() work, {
    bool isImport = false,
  }) async {
    if (busy) return;
    busy = true;
    importing = isImport;
    error = null;
    notice = null;
    progress = null;
    _notify();
    try {
      await work();
    } catch (e) {
      debugPrint('Photo library: $e');
      error = '照片读取或保存失败，请检查权限和存储空间后重试';
    } finally {
      busy = false;
      importing = false;
      progress = null;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

Future<void> _writeJson(File file, Object value) async {
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(jsonEncode(value), flush: true);
  await temporary.rename(file.path);
}

Future<ui.Size> _preparePhoto(String path, Directory directory) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(path);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    for (final (name, edge) in [('photo', 1920), ('thumb', 256)]) {
      final scale = math.min(
        1.0,
        edge / math.max(descriptor.width, descriptor.height),
      );
      final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      try {
        final image = (await codec.getNextFrame()).image;
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          if (bytes == null) throw StateError('无法读取照片');
          await File('${directory.path}/$name.png').writeAsBytes(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
            flush: true,
          );
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    }
    return ui.Size(descriptor.width.toDouble(), descriptor.height.toDouble());
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}
