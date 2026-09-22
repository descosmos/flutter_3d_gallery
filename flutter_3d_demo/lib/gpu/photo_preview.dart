import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

Future<void> showPhotoPreview(BuildContext context, String asset) =>
    showPhotoGallery(context, [asset]);

Future<void> showPhotoGallery(BuildContext context, List<String> assets) {
  if (assets.isEmpty) return Future.value();
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭照片浏览',
    barrierColor: const Color(0x55000000),
    transitionDuration: const Duration(milliseconds: 220),
    transitionBuilder: (context, animation, secondary, child) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween(begin: .94, end: 1.0).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: child,
      ),
    ),
    pageBuilder: (context, _, _) =>
        PhotoPreview.gallery(assets: List.unmodifiable(assets)),
  );
}

Map<String, String>? _previewPaths;
Set<String>? _assetManifest;
Future<List<String>> _resolveAssets(List<String> assets) async {
  final paths = _previewPaths ??=
      ((jsonDecode(await rootBundle.loadString('assets/texture_aliases.json'))
                  as Map)['previewAssets']
              as Map?)
          ?.cast<String, String>() ??
      <String, String>{};
  final manifest = _assetManifest ??= (await AssetManifest.loadFromAssetBundle(
    rootBundle,
  )).listAssets().toSet();
  return [
    for (final asset in assets)
      paths['assets/thumbs/${asset.split('/').last}'] ??
          (manifest.contains('assets/photos/${asset.split('/').last}')
              ? 'assets/photos/${asset.split('/').last}'
              : asset),
  ];
}

class PhotoPreview extends StatefulWidget {
  const PhotoPreview({super.key, required this.asset}) : assets = const [];
  const PhotoPreview.gallery({super.key, required this.assets}) : asset = null;
  final String? asset;
  final List<String> assets;
  @override
  State<PhotoPreview> createState() => _PhotoPreviewState();
}

class _PhotoPreviewState extends State<PhotoPreview> {
  final _pager = PageController();
  final _decoded = <String>{};
  final _pointers = <int>{};
  late final List<String> _photos = widget.asset == null
      ? widget.assets
      : [widget.asset!];
  List<String>? _resolved;
  String? _error;
  int _index = 0;
  bool _zoomed = false, _multiTouch = false;
  Drag? _pageDrag;
  final _pageKeys = <int, GlobalKey<_ZoomablePhotoState>>{};

  @override
  void initState() {
    super.initState();
    _resolveAssets(_photos).then(
      (paths) {
        if (mounted) setState(() => _resolved = paths);
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = '$e');
      },
    );
  }

  void _pointerEnded(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.isEmpty && _multiTouch) setState(() => _multiTouch = false);
  }

  // 缩放控件统一接收手势，普通单指拖动再交给 PageView。
  // 不让两套 recognizer 竞争，避免设备触摸阈值不同导致翻页失效。
  void _startDrag(ScaleStartDetails details) {
    _pageDrag?.cancel();
    _pageDrag = null;
    if (_zoomed || _multiTouch || details.pointerCount != 1) return;
    _pageDrag = _pager.position.drag(
      DragStartDetails(
        globalPosition: details.focalPoint,
        localPosition: details.localFocalPoint,
      ),
      () => _pageDrag = null,
    );
  }

  void _updateDrag(ScaleUpdateDetails details) {
    if (_multiTouch || _zoomed) return;
    _pageDrag?.update(
      DragUpdateDetails(
        delta: Offset(details.focalPointDelta.dx, 0),
        primaryDelta: details.focalPointDelta.dx,
        globalPosition: details.focalPoint,
        localPosition: details.localFocalPoint,
      ),
    );
  }

  void _endDrag(ScaleEndDetails details) {
    _pageDrag?.end(
      DragEndDetails(
        velocity: Velocity(
          pixelsPerSecond: Offset(details.velocity.pixelsPerSecond.dx, 0),
        ),
        primaryVelocity: details.velocity.pixelsPerSecond.dx,
      ),
    );
    _pageDrag = null;
  }

  void _trimImages() {
    if (!mounted || _resolved == null) return;
    final keep = _resolved!
        .sublist(math.max(0, _index - 1), math.min(_photos.length, _index + 2))
        .toSet();
    for (final path in _decoded.difference(keep).toList()) {
      AssetImage(path).evict();
      _decoded.remove(path);
    }
    _pageKeys.removeWhere((i, key) => (i - _index).abs() > 1);
  }

  void _changePage(int index) {
    _pageKeys[_index]?.currentState?.reset();
    setState(() {
      _index = index;
      _zoomed = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _trimImages());
  }

  void _step(int delta) {
    if (!_pager.hasClients) return;
    final next = (_index + delta).clamp(0, _photos.length - 1);
    if (next == _index) return;
    _pageKeys[_index]?.currentState?.reset();
    _pager.animateToPage(
      next,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _pageDrag?.cancel();
    _pager.dispose();
    for (final path in _decoded) {
      AssetImage(path).evict();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(760.0, constraints.maxWidth - 32);
        final height = math.min(constraints.maxHeight - 40, width * 1.55);
        return Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              key: const ValueKey('photo-preview'),
              width: width,
              height: height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .24),
                    blurRadius: 30,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFF142132).withValues(alpha: .36),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: .3),
                      ),
                    ),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(
                            left: 20,
                            right: 6,
                            top: 6,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _photos.length > 1 ? '地点相册' : '大图预览',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              IconButton(
                                key: const ValueKey('photo-preview-close'),
                                tooltip: '关闭照片浏览',
                                onPressed: () => Navigator.pop(context),
                                icon: const Icon(Icons.close, size: 22),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: _resolved == null
                                  ? Center(
                                      child: _error == null
                                          ? const CircularProgressIndicator()
                                          : const Text('图片暂时无法加载'),
                                    )
                                  : Listener(
                                      onPointerDown: (e) {
                                        _pointers.add(e.pointer);
                                        if (_pointers.length > 1 &&
                                            !_multiTouch) {
                                          _pageDrag?.cancel();
                                          _pageDrag = null;
                                          setState(() => _multiTouch = true);
                                        }
                                      },
                                      onPointerUp: (e) =>
                                          _pointerEnded(e.pointer),
                                      onPointerCancel: (e) =>
                                          _pointerEnded(e.pointer),
                                      child: PageView.builder(
                                        key: const ValueKey(
                                          'photo-gallery-pages',
                                        ),
                                        controller: _pager,
                                        physics:
                                            const NeverScrollableScrollPhysics(),
                                        itemCount: _photos.length,
                                        onPageChanged: _changePage,
                                        itemBuilder: (context, index) {
                                          final asset = _resolved![index];
                                          _decoded.add(asset);
                                          return _ZoomablePhoto(
                                            key: _pageKeys.putIfAbsent(
                                              index,
                                              () =>
                                                  GlobalKey<
                                                    _ZoomablePhotoState
                                                  >(),
                                            ),
                                            asset: asset,
                                            current: index == _index,
                                            onInteractionStart: _startDrag,
                                            onInteractionUpdate: _updateDrag,
                                            onInteractionEnd: _endDrag,
                                            onZoomChanged: (zoomed) {
                                              if (mounted &&
                                                  index == _index &&
                                                  zoomed != _zoomed) {
                                                setState(
                                                  () => _zoomed = zoomed,
                                                );
                                              }
                                            },
                                          );
                                        },
                                      ),
                                    ),
                            ),
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (_photos.length > 1)
                              IconButton(
                                tooltip: '上一张照片',
                                onPressed: _resolved != null && _index > 0
                                    ? () => _step(-1)
                                    : null,
                                icon: const Icon(Icons.chevron_left_rounded),
                              ),
                            Text(
                              '${_index + 1} / ${_photos.length}',
                              key: const ValueKey('photo-gallery-counter'),
                              style: const TextStyle(
                                fontSize: 13,
                                color: Colors.white70,
                              ),
                            ),
                            if (_photos.length > 1)
                              IconButton(
                                tooltip: '下一张照片',
                                onPressed:
                                    _resolved != null &&
                                        _index < _photos.length - 1
                                    ? () => _step(1)
                                    : null,
                                icon: const Icon(Icons.chevron_right_rounded),
                              ),
                            IconButton(
                              tooltip: '还原图片',
                              onPressed: _zoomed
                                  ? () =>
                                        _pageKeys[_index]?.currentState?.reset()
                                  : null,
                              icon: const Icon(Icons.fit_screen, size: 20),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Text(
                            _zoomed
                                ? '拖动查看细节 · 双指缩小或双击还原'
                                : _photos.length > 1
                                ? '左右滑动切图 · 双指缩放'
                                : '双指缩放 · 双击放大',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white60,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _ZoomablePhoto extends StatefulWidget {
  const _ZoomablePhoto({
    super.key,
    required this.asset,
    required this.current,
    required this.onZoomChanged,
    required this.onInteractionStart,
    required this.onInteractionUpdate,
    required this.onInteractionEnd,
  });
  final String asset;
  final bool current;
  final ValueChanged<bool> onZoomChanged;
  final GestureScaleStartCallback onInteractionStart;
  final GestureScaleUpdateCallback onInteractionUpdate;
  final GestureScaleEndCallback onInteractionEnd;
  @override
  State<_ZoomablePhoto> createState() => _ZoomablePhotoState();
}

class _ZoomablePhotoState extends State<_ZoomablePhoto> {
  final _transform = TransformationController();
  Offset _doubleTap = Offset.zero;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_changed);
  }

  void _changed() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) {
      setState(() => _zoomed = zoomed);
      widget.onZoomChanged(zoomed);
    }
  }

  void reset() => _transform.value = Matrix4.identity();

  @override
  void dispose() {
    _transform.removeListener(_changed);
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onDoubleTapDown: (d) => _doubleTap = d.localPosition,
    onDoubleTap: () {
      if (_zoomed) {
        reset();
        return;
      }
      const scale = 2.5;
      _transform.value = Matrix4.identity()
        ..translateByDouble(
          -_doubleTap.dx * (scale - 1),
          -_doubleTap.dy * (scale - 1),
          0,
          1,
        )
        ..scaleByDouble(scale, scale, 1, 1);
    },
    child: InteractiveViewer(
      transformationController: _transform,
      minScale: 1,
      maxScale: 5,
      panEnabled: _zoomed,
      onInteractionStart: widget.onInteractionStart,
      onInteractionUpdate: widget.onInteractionUpdate,
      onInteractionEnd: widget.onInteractionEnd,
      child: SizedBox.expand(
        child: Image.asset(
          widget.asset,
          key: widget.current ? const ValueKey('photo-preview-image') : null,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Center(child: Text('图片暂时无法加载')),
        ),
      ),
    ),
  );
}
