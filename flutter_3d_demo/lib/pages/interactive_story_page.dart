import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../player/particles.dart';
import '../player/spatial_photo.dart';
import '../story/photo_geo.dart';
import '../story/story_models.dart';
import 'photo_map_page.dart';

/// 交互式 3D 回忆空间：照片在纵深空间排成环形阵列，
/// 左右拖动环视、焦点卡视差、章节直达、GPS 路线图点选跳转。
class InteractiveStoryPage extends StatefulWidget {
  const InteractiveStoryPage({super.key, required this.story});

  final StorySpec story;

  @override
  State<InteractiveStoryPage> createState() => _InteractiveStoryPageState();
}

class StoryItem {
  const StoryItem({
    required this.asset,
    required this.chapterTitle,
    required this.chapterIndex,
    this.caption,
    this.portrait = false,
    this.geo,
  });

  final String asset;
  final String chapterTitle;
  final int chapterIndex;
  final String? caption;
  final bool portrait;
  final GeoPoint? geo;
}

class _InteractiveStoryPageState extends State<InteractiveStoryPage>
    with TickerProviderStateMixin {
  late final List<StoryItem> _items;
  late final List<int> _chapterFirstItem;

  double _focusFloat = 0;
  late final AnimationController _snap;
  double _snapFrom = 0, _snapTo = 0;
  late final AnimationController _time;

  Offset _parallax = Offset.zero;
  late final AnimationController _parallaxReset;
  Offset _parallaxStart = Offset.zero;

  bool _uiVisible = true;
  bool _mapVisible = false;
  late final AnimationController _mapProgress;

  static const double _spacing = 0.26; // 相邻卡片角度间隔（弧度）

  @override
  void initState() {
    super.initState();
    _items = _buildItems();
    _chapterFirstItem = _buildChapterIndex();
    _snap = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 420))
      ..addListener(() {
        setState(() {
          _focusFloat = ui.lerpDouble(_snapFrom, _snapTo,
              Curves.easeOutCubic.transform(_snap.value))!;
        });
      });
    _time = AnimationController(vsync: this, duration: const Duration(seconds: 10))
      ..repeat();
    _parallaxReset = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 350))
      ..addListener(() {
        setState(() {
          _parallax = Offset.lerp(_parallaxStart, Offset.zero,
              Curves.easeOut.transform(_parallaxReset.value))!;
        });
      });
    _mapProgress = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final item in _items) {
        precacheImage(AssetImage(item.asset), context);
      }
    });
  }

  List<StoryItem> _buildItems() {
    final items = <StoryItem>[];
    for (int ci = 0; ci < widget.story.chapters.length; ci++) {
      final chapter = widget.story.chapters[ci];
      if (chapter.title == '片尾') continue;
      for (final shot in chapter.shots) {
        final thumb = 'assets/thumbs/${shot.asset.split('/').last}';
        items.add(StoryItem(
          asset: shot.asset,
          chapterTitle: chapter.title,
          chapterIndex: ci,
          caption: shot.caption,
          portrait: shot.portrait,
          geo: photoGeo[thumb],
        ));
      }
    }
    return items;
  }

  List<int> _buildChapterIndex() {
    final first = <int>[];
    for (int i = 0; i < _items.length; i++) {
      if (_items[i].chapterIndex == first.length) {
        first.add(i);
      }
    }
    return first;
  }

  int get _focusIndex =>
      _focusFloat.round().clamp(0, _items.length - 1);

  @override
  void dispose() {
    _snap.dispose();
    _time.dispose();
    _parallaxReset.dispose();
    _mapProgress.dispose();
    super.dispose();
  }

  void _snapToIndex(int index) {
    _snapFrom = _focusFloat;
    _snapTo = index.clamp(0, _items.length - 1).toDouble();
    _snap.forward(from: 0);
  }

  void _onOrbitDrag(DragUpdateDetails d, double width) {
    _snap.stop();
    setState(() {
      _focusFloat = (_focusFloat - d.delta.dx * 0.012)
          .clamp(-0.6, _items.length - 1 + 0.6);
    });
  }

  void _onOrbitEnd(DragEndDetails d) {
    final v = -d.velocity.pixelsPerSecond.dx;
    int target = _focusFloat.round();
    if (v.abs() > 400) {
      target += (v / 900).round().clamp(-3, 3);
    }
    _snapToIndex(target);
  }

  void _onParallaxDrag(DragUpdateDetails d) {
    _parallaxReset.stop();
    setState(() {
      _parallax = Offset(
        (_parallax.dx + d.delta.dx / 260).clamp(-1.0, 1.0),
        (_parallax.dy + d.delta.dy / 260).clamp(-1.0, 1.0),
      );
    });
  }

  void _onParallaxEnd(DragEndDetails _) {
    _parallaxStart = _parallax;
    _parallaxReset.forward(from: 0);
  }

  void _toggleMap() {
    setState(() => _mapVisible = !_mapVisible);
    if (_mapVisible) {
      _mapProgress.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _items[_focusIndex];
    return Scaffold(
      backgroundColor: const Color(0xFF05080E),
      body: AnimatedBuilder(
        animation: _time,
        builder: (context, _) {
          final t = _time.value * 10;
          return Stack(
            fit: StackFit.expand,
            children: [
              _Ambient(asset: item.asset),
              ParticleField(time: t, opacity: 0.7),
              _buildOrbitRing(context),
              _buildFocusedCard(context, item),
              if (_uiVisible && !_mapVisible) ...[
                _buildTopBar(),
                _buildBottom(item),
              ],
              if (_mapVisible) _buildMapOverlay(context, t),
            ],
          );
        },
      ),
    );
  }

  /// 环形照片阵列：焦点两侧向空间深处排开
  Widget _buildOrbitRing(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stage = constraints.biggest;
        final center = Offset(stage.width / 2, stage.height * 0.44);
        final radius = stage.width * 0.62;

        final cards = <MapEntry<int, double>>[];
        for (int i = 0; i < _items.length; i++) {
          if (i == _focusIndex) continue;
          final a = (i - _focusFloat) * _spacing;
          if (a.abs() > 2.4) continue;
          cards.add(MapEntry(i, a));
        }
        // 先画远处（z 小），后画近处
        cards.sort((a, b) =>
            math.cos(a.value).compareTo(math.cos(b.value)));

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => _onOrbitDrag(d, stage.width),
          onHorizontalDragEnd: _onOrbitEnd,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const SizedBox.shrink(),
              for (final e in cards)
                () {
                  final i = e.key;
                  final a = e.value;
                  final z = math.cos(a); // 1 最近 … -1 最远
                  final near = (z + 1) / 2;
                  final w = ui.lerpDouble(72, 150, near)!;
                  final it = _items[i];
                  final h = it.portrait ? w * 4 / 3 : w * 3 / 4;
                  final x = center.dx + math.sin(a) * radius;
                  final y = center.dy - near * 26 + a.abs() * 10;
                  final m = Matrix4.identity()
                    ..setEntry(3, 2, 0.0015)
                    ..translateByDouble(x - w / 2, y - h / 2, (z - 1) * 160, 1)
                    ..rotateY(-a * 0.55);
                  return Positioned(
                    left: 0,
                    top: 0,
                    child: Transform(
                      alignment: Alignment.center,
                      transform: m,
                      child: Opacity(
                        opacity: ui.lerpDouble(0.25, 0.95, near)!,
                        child: _RingCard(
                          item: it,
                          width: w,
                          onTap: () => _snapToIndex(i),
                        ),
                      ),
                    ),
                  );
                }(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFocusedCard(BuildContext context, StoryItem item) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stage = constraints.biggest;
        final w = item.portrait ? stage.width * 0.5 : stage.width * 0.68;
        return Padding(
          padding: EdgeInsets.only(top: stage.height * 0.44 - w * 0.33),
          child: GestureDetector(
            onTap: () => setState(() => _uiVisible = !_uiVisible),
            onVerticalDragUpdate: _onParallaxDrag,
            onVerticalDragEnd: _onParallaxEnd,
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: ScaleTransition(
                    scale: Tween(begin: 0.94, end: 1.0).animate(anim),
                    child: child,
                  ),
                ),
                child: Transform(
                  key: ValueKey(_focusIndex),
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.0012)
                    ..rotateY(_parallax.dx * 0.14)
                    ..rotateX(-_parallax.dy * 0.08),
                  child: SpatialPhotoCard(
                    asset: item.asset,
                    width: w,
                    portrait: item.portrait,
                    parallax: _parallax,
                    layerSpread: 1.15,
                    glow: 0.5,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new,
                    color: Colors.white, size: 20),
                onPressed: () => Navigator.of(context).pop(),
              ),
              const Expanded(
                child: Center(
                  child: Text('3D 回忆空间',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600)),
                ),
              ),
              IconButton(
                tooltip: '3D 照片地图',
                icon: const Icon(Icons.map_outlined, color: Colors.white),
                onPressed: _toggleMap,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottom(StoryItem item) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black.withValues(alpha: 0.7),
              ],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  item.caption ?? '${item.chapterTitle} · 第 ${_focusIndex + 1} 张',
                  key: ValueKey(item.caption ?? _focusIndex),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 15, color: Colors.white, letterSpacing: 0.5),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (int ci = 0; ci < widget.story.chapters.length - 1; ci++)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _ChapterChip(
                          title: widget.story.chapters[ci].title,
                          active: item.chapterIndex == ci,
                          onTap: () => _snapToIndex(_chapterFirstItem[ci]),
                        ),
                      ),
                    _ChapterChip(
                      title: '3D 地图',
                      icon: Icons.map_outlined,
                      active: false,
                      onTap: _toggleMap,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '左右滑动环视空间 · 拖动照片查看层次',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.45)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMapOverlay(BuildContext context, double t) {
    final markers = [
      for (int i = 0; i < _items.length; i++)
        if (_items[i].geo != null)
          PhotoMapMarker(
            storyIndex: i,
            thumbAsset: 'assets/thumbs/${_items[i].asset.split('/').last}',
            point: _items[i].geo!,
          ),
    ];
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _mapProgress,
        builder: (context, _) => Opacity(
          opacity: Curves.easeOut.transform(_mapProgress.value),
          child: PhotoMapView(
            markers: markers,
            focusIndex: _focusIndex,
            onSelectStory: _snapToIndex,
            onClose: _toggleMap,
          ),
        ),
      ),
    );
  }
}

class _RingCard extends StatelessWidget {
  const _RingCard({required this.item, required this.width, required this.onTap});

  final StoryItem item;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final h = item.portrait ? width * 4 / 3 : width * 3 / 4;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: width,
        height: h,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.45), blurRadius: 12),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset(item.asset, fit: BoxFit.cover),
        ),
      ),
    );
  }
}

class _ChapterChip extends StatelessWidget {
  const _ChapterChip({
    required this.title,
    required this.active,
    required this.onTap,
    this.icon,
  });

  final String title;
  final bool active;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          color: active
              ? Colors.white.withValues(alpha: 0.9)
              : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(17),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: 13,
                  color: active ? Colors.black87 : Colors.white70),
              const SizedBox(width: 4),
            ],
            Text(
              title,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active ? Colors.black87 : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Ambient extends StatelessWidget {
  const _Ambient({required this.asset});

  final String asset;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 46, sigmaY: 46),
          child: Transform.scale(
            scale: 1.35,
            child: Image.asset(asset, fit: BoxFit.cover),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xE605080E), Color(0x8805080E), Color(0xF205080E)],
            ),
          ),
        ),
      ],
    );
  }
}
