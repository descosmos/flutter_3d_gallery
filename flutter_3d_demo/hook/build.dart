import 'dart:convert';
import 'dart:io';

import 'package:flutter_scene/build_hooks.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
        // Import .glb and .fscene sources under assets/, loadable by source path
    // with loadScene (and hot-reloadable). A no-op when there are no scenes.
    buildScenes(buildInput: input, buildOutput: output);
    // 同源替代图片共用一份 GPU 压缩纹理，避免把 632 个别名重复上传。
    final aliases = File.fromUri(
      input.packageRoot.resolve('assets/texture_aliases.json'),
    );
    final manifest =
        jsonDecode(aliases.readAsStringSync()) as Map<String, dynamic>;
    output.dependencies.add(aliases.uri);
    buildTextures(
      buildInput: input,
      buildOutput: output,
      textures: (manifest['gpuTextures'] as List).cast<String>(),
      alignForCompression: true,
    );
    // Compile .fmat materials under assets/, loadable by source path with
    // loadFmatMaterial (and hot-reloadable). A no-op when there are none.
    await buildMaterials(buildInput: input, buildOutput: output);
      });
}
