import 'dart:ui' as ui;

import 'package:flutter_scene/scene.dart' as fs;

// flutter_scene 0.23 的异步 mip 生成尚未从主入口导出。
// 在此集中复用 SDK 的过滤、能力探测与上传实现，保持像素和采样方式一致。
// 升级依赖时需验证这个适配层；pubspec 已固定对应版本。
// ignore: implementation_imports
import 'package:flutter_scene/src/render/mip_sampling_probe.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/texture/mipmap_async.dart';
// ignore: implementation_imports
import 'package:flutter_scene/src/texture/texture2d.dart' show uploadMipLevels;

Future<fs.TextureSource> textureFromImageAsync(
  ui.Image image, {
  required fs.TextureSampling sampling,
  required bool Function() isAlive,
}) async {
  final data = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  if (data == null) throw StateError('无法读取贴图像素');
  if (!isAlive()) throw StateError('场景已关闭');
  final pixels = data.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );
  if (!sampling.mipmaps || !mipChainsAreSampled) {
    return fs.Texture2D.fromPixels(
      pixels,
      image.width,
      image.height,
      sampling: sampling,
    );
  }
  final levels = await generateMipChainAsync(
    pixels,
    image.width,
    image.height,
    fs.TextureContent.color,
  );
  if (!isAlive()) throw StateError('场景已关闭');
  final texture = uploadMipLevels(
    levels,
    image.width,
    image.height,
    maxMipmapLevels: sampling.maxMipmapLevels,
  );
  return fs.GpuTextureSource(texture, sampler: sampling.toSamplerOptions());
}
