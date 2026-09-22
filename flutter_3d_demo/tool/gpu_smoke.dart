import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

void main() => runApp(const MaterialApp(home: _GpuSmoke()));

class _GpuSmoke extends StatefulWidget {
  const _GpuSmoke();
  @override
  State<_GpuSmoke> createState() => _GpuSmokeState();
}

class _GpuSmokeState extends State<_GpuSmoke> {
  final scene = fs.Scene();
  bool ready = false;
  String? error;
  @override
  void initState() {
    super.initState();
    fs.Scene.initializeStaticResources()
        .then((_) {
          scene.add(
            fs.Node(
              mesh: fs.Mesh(
                fs.CuboidGeometry(vm.Vector3(1, 1, 1)),
                fs.PhysicallyBasedMaterial()
                  ..baseColorFactor = vm.Vector4(0.04, 0.5, 1, 1),
              ),
            ),
          );
          scene.add(
            fs.Node(
              mesh: fs.Mesh(
                fs.PlaneGeometry(width: 10, depth: 10),
                fs.PhysicallyBasedMaterial()
                  ..baseColorFactor = vm.Vector4(0.04, 0.05, 0.08, 1),
              ),
            )..position = vm.Vector3(0, -0.7, 0),
          );
          if (mounted) setState(() => ready = true);
        })
        .catchError((Object e, StackTrace s) {
          debugPrint('$e\n$s');
          if (mounted) setState(() => error = '$e');
        });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ready
        ? fs.SceneView(
            scene,
            camera: fs.PerspectiveCamera(position: vm.Vector3(3, 2, -5)),
          )
        : Center(child: Text(error ?? '正在初始化 Flutter GPU')),
  );
}
