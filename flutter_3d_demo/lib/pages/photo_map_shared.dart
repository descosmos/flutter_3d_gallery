// 3D 照片地图共享组件：标记数据、头部、提示、双击放大浮层。
import 'package:flutter/material.dart';

import '../player/spatial_photo.dart';
import '../story/photo_geo.dart';

class PhotoMapMarker {
  const PhotoMapMarker({
    required this.storyIndex,
    required this.thumbAsset,
    required this.point,
  });

  final int storyIndex;
  final String thumbAsset;
  final GeoPoint point;
}

/// 地图顶部标题栏
class MapHeader extends StatelessWidget {
  const MapHeader({super.key, required this.onClose, this.subtitle});

  final VoidCallback onClose;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0.72), Colors.transparent],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('3D 照片地图',
                          style: TextStyle(
                              color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w600)),
                      Text(subtitle ?? '${photoGeo.length} 张照片 · 按 GPS 定位',
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withValues(alpha: 0.55))),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部操作提示
class MapHint extends StatelessWidget {
  const MapHint({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 26,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(
            '拖动浏览 · 点按卡片飞往拍摄地 · 双击放大',
            style: TextStyle(
                fontSize: 12, color: Colors.white.withValues(alpha: 0.7)),
          ),
        ),
      ),
    );
  }
}

/// 双击标记后的大图浏览浮层：全屏 + 拖动视差，点按关闭
class PhotoPeekOverlay extends StatefulWidget {
  const PhotoPeekOverlay({super.key, required this.asset, required this.onClose});

  final String asset;
  final VoidCallback onClose;

  @override
  State<PhotoPeekOverlay> createState() => _PhotoPeekOverlayState();
}

class _PhotoPeekOverlayState extends State<PhotoPeekOverlay>
    with SingleTickerProviderStateMixin {
  Offset _parallax = Offset.zero;
  Offset _from = Offset.zero;
  late final AnimationController _reset;

  @override
  void initState() {
    super.initState();
    _reset = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 320))
      ..addListener(() {
        setState(() {
          _parallax = Offset.lerp(
              _from, Offset.zero, Curves.easeOut.transform(_reset.value))!;
        });
      });
  }

  @override
  void dispose() {
    _reset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width * 0.84;
    return Positioned.fill(
      child: GestureDetector(
        onTap: widget.onClose,
        child: Container(
          color: Colors.black.withValues(alpha: 0.88),
          child: Center(
            child: GestureDetector(
              onPanUpdate: (d) {
                _reset.stop();
                setState(() {
                  _parallax = Offset(
                    (_parallax.dx + d.delta.dx / 300).clamp(-1.0, 1.0),
                    (_parallax.dy + d.delta.dy / 300).clamp(-1.0, 1.0),
                  );
                });
              },
              onPanEnd: (_) {
                _from = _parallax;
                _reset.forward(from: 0);
              },
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0012)
                  ..rotateY(_parallax.dx * 0.16)
                  ..rotateX(-_parallax.dy * 0.10),
                child: SpatialPhotoCard(
                  asset: widget.asset,
                  width: w,
                  parallax: _parallax,
                  layerSpread: 1.2,
                  glow: 0.6,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
