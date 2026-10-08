import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

bool isLocalPhoto(String path) => path.startsWith('/');

String photoThumbnail(String path) => isLocalPhoto(path)
    ? '${File(path).parent.path}/thumb.png'
    : 'assets/thumbs/${path.split('/').last}';

String localPhotoPreview(String path) => '${File(path).parent.path}/photo.png';

ImageProvider photoImageProvider(String path) =>
    isLocalPhoto(path) ? FileImage(File(path)) : AssetImage(path);

Future<Uint8List> photoBytes(String path) async {
  if (isLocalPhoto(path)) return File(path).readAsBytes();
  final data = await rootBundle.load(path);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
