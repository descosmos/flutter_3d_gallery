import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../story/story_models.dart';
import 'particles.dart';
import 'story_scene.dart';

/// 导演模式播放器：系统按镜头脚本自动播放，用户可暂停、章节跳转，
/// 并在互动镜头拖动产生小范围空间观察（松手平滑回到导演轨迹）。
class StoryController extends ChangeNotifier {
  StoryController({required this.story, required TickerProvider vsync}) {
    _ticker = vsync.createTicker(_onTick);
  }

  final StorySpec story;
  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  double position = 0;
  bool playing = false;
  bool ended = false;

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    position += dt;
    if (position >= story.totalDuration) {
      position = story.totalDuration;
      ended = true;
      _stop();
    }
    notifyListeners();
  }

  void play() {
    if (playing) return;
    if (ended) {
      position = 0;
      ended = false;
    }
    playing = true;
    _lastElapsed = Duration.zero;
    _ticker.start();
    notifyListeners();
  }

  void pause() {
    if (!playing) return;
    _stop();
    notifyListeners();
  }

  void _stop() {
    playing = false;
    _ticker.stop();
  }

  void toggle() => playing ? pause() : play();

  void seekTo(double seconds) {
    position = seconds.clamp(0.0, story.totalDuration);
    ended = false;
    notifyListeners();
  }

  void skipToChapter(int chapterIndex) {
    final starts = story.chapterStarts;
    if (chapterIndex < 0 || chapterIndex >= starts.length) return;
    seekTo(starts[chapterIndex] + 0.001);
    if (!playing && !ended) play();
    if (ended) play();
  }

  void skipChapter(int delta) {
    final loc = story.locate(position);
    int target = loc.chapterIndex + delta;
    // 回退时若本章已播放超过 1.5 秒，先回本章开头
    if (delta < 0 &&
        position - story.chapterStarts[loc.chapterIndex] > 1.5) {
      target = loc.chapterIndex;
    }
    skipToChapter(target.clamp(0, story.chapters.length - 1));
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

class StoryPlayerPage extends StatefulWidget {
  const StoryPlayerPage({super.key, required this.story, this.startAt = 0});

  final StorySpec story;
  final double startAt;

  @override
  State<StoryPlayerPage> createState() => _StoryPlayerPageState();
}

class _StoryPlayerPageState extends State<StoryPlayerPage>
    with TickerProviderStateMixin {
  late final StoryController _controller;
  bool _uiVisible = true;
  Offset _parallax = Offset.zero;
  late final AnimationController _parallaxReset;

  @override
  void initState() {
    super.initState();
    _controller = StoryController(story: widget.story, vsync: this)
      ..addListener(_onChanged);
    _controller.position = widget.startAt;
    _controller.play();
    _parallaxReset = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    )..addListener(() {
        setState(() {
          _parallax = Offset.lerp(_parallaxStart, Offset.zero,
              Curves.easeOut.transform(_parallaxReset.value))!;
        });
      });
    WidgetsBinding.instance.addPostFrameCallback((_) => _precache());
  }

  Offset _parallaxStart = Offset.zero;

  void _precache() {
    for (final chapter in widget.story.chapters) {
      for (final shot in chapter.shots) {
        precacheImage(AssetImage(shot.asset), context);
        for (final extra in shot.extraAssets) {
          precacheImage(AssetImage(extra), context);
        }
      }
    }
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _parallaxReset.dispose();
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details, double width) {
    _parallaxReset.stop();
    setState(() {
      _parallax = Offset(
        (_parallax.dx + details.delta.dx / (width * 0.35)).clamp(-1.0, 1.0),
        (_parallax.dy + details.delta.dy / 600).clamp(-1.0, 1.0),
      );
    });
  }

  void _onDragEnd(DragEndDetails _) {
    _parallaxStart = _parallax;
    _parallaxReset.forward(from: 0);
  }

  String _fmt(double seconds) {
    final s = seconds.floor();
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final story = widget.story;
    final loc = story.locate(_controller.position);
    final chapter = story.chapters[loc.chapterIndex];
    final shot = chapter.shots[loc.shotIndex];

    final particleOpacity = switch (chapter.title) {
      '雪山' || '尾声' || '片尾' => 1.0,
      _ => 0.55,
    };

    return Scaffold(
      backgroundColor: const Color(0xFF06090F),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _uiVisible = !_uiVisible),
        onHorizontalDragUpdate: (d) =>
            _onDragUpdate(d, MediaQuery.of(context).size.width),
        onHorizontalDragEnd: _onDragEnd,
        onVerticalDragUpdate: (d) =>
            _onDragUpdate(d, MediaQuery.of(context).size.width),
        onVerticalDragEnd: _onDragEnd,
        child: Stack(
          fit: StackFit.expand,
          children: [
            StoryScene(
              story: story,
              time: _controller.position,
              parallax: shot.interactive ? _parallax : _parallax * 0.4,
            ),
            ParticleField(time: _controller.position, opacity: particleOpacity),

            // 开场空间字幕
            if (loc.globalShotIndex == 0)
              Positioned(
                top: MediaQuery.of(context).size.height * 0.16,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: (1 - Curves.easeIn.transform(loc.progress))
                        .clamp(0.0, 1.0),
                    child: Column(
                      children: [
                        Text(
                          story.title,
                          style: const TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            letterSpacing: 3,
                            shadows: [
                              Shadow(color: Colors.black87, blurRadius: 16)
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          story.dateLabel,
                          style: TextStyle(
                            fontSize: 15,
                            letterSpacing: 2,
                            color: Colors.white.withValues(alpha: 0.85),
                            shadows: const [
                              Shadow(color: Colors.black87, blurRadius: 10)
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // 镜头字幕
            Positioned(
              left: 32,
              right: 32,
              bottom: 132,
              child: IgnorePointer(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 500),
                  child: shot.caption == null
                      ? const SizedBox.shrink()
                      : Text(
                          shot.caption!,
                          key: ValueKey(shot.caption),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 17,
                            height: 1.5,
                            color: Colors.white,
                            letterSpacing: 1,
                            shadows: [
                              Shadow(color: Colors.black87, blurRadius: 12)
                            ],
                          ),
                        ),
                ),
              ),
            ),

            if (_uiVisible && !_controller.ended) ...[
              _buildTopBar(loc, chapter, shot),
              // 章节指示（设计稿位于顶栏下方左侧）
              Positioned(
                top: 78,
                left: 18,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white24, width: 0.5),
                  ),
                  child: Text(
                    '章节 ${loc.chapterIndex + 1}/${story.chapters.length} · ${chapter.title}',
                    style: const TextStyle(fontSize: 12, color: Colors.white),
                  ),
                ),
              ),
              _buildBottomBar(story),
            ],

            if (shot.interactive && _uiVisible && !_controller.ended)
              Positioned(
                top: 112,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white24, width: 0.5),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.swap_horiz,
                            size: 15, color: Colors.white70),
                        SizedBox(width: 5),
                        Text('左右滑动可查看空间层次',
                            style: TextStyle(
                                fontSize: 12, color: Colors.white70)),
                      ],
                    ),
                  ),
                ),
              ),

            if (_controller.ended) _buildEndOverlay(story),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(ShotLocation loc, ChapterSpec chapter, ShotSpec shot) {
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
                  child: Text(
                    '3D回忆故事',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.more_horiz, color: Colors.white),
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(StorySpec story) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black.withValues(alpha: 0.65),
              ],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ProgressBar(
                story: story,
                position: _controller.position,
                onSeek: (t) => _controller.seekTo(t),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(_controller.position),
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white70)),
                  Text(_fmt(story.totalDuration),
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white70)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _ControlButton(
                    icon: Icons.skip_previous,
                    label: '上一幕',
                    onTap: () => _controller.skipChapter(-1),
                  ),
                  const SizedBox(width: 36),
                  _ControlButton(
                    icon: _controller.playing ? Icons.pause : Icons.play_arrow,
                    label: _controller.playing ? '暂停' : '播放',
                    size: 58,
                    onTap: _controller.toggle,
                  ),
                  const SizedBox(width: 36),
                  _ControlButton(
                    icon: Icons.skip_next,
                    label: '下一幕',
                    onTap: () => _controller.skipChapter(1),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEndOverlay(StorySpec story) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.55),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _EndAction(
                  icon: Icons.replay,
                  label: '重新播放',
                  onTap: () {
                    _controller.seekTo(0);
                    _controller.play();
                  },
                ),
                const SizedBox(width: 28),
                _EndAction(
                  icon: Icons.ios_share,
                  label: '分享',
                  onTap: () {},
                ),
                const SizedBox(width: 28),
                _EndAction(
                  icon: Icons.check_circle_outline,
                  label: '完成',
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.story,
    required this.position,
    required this.onSeek,
  });

  final StorySpec story;
  final double position;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        void seekAt(double dx) =>
            onSeek((dx / w).clamp(0.0, 1.0) * story.totalDuration);
        final fraction =
            (position / story.totalDuration).clamp(0.0, 1.0);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => seekAt(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => seekAt(d.localPosition.dx),
          child: SizedBox(
            height: 22,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: fraction,
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                for (final start in story.chapterStarts.skip(1))
                  Positioned(
                    left: (start / story.totalDuration) * w - 3,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: position >= start
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                Positioned(
                  left: fraction * w - 6,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.size = 46,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white70, width: 1.2),
            ),
            child: Icon(icon, color: Colors.white, size: size * 0.45),
          ),
        ),
        const SizedBox(height: 5),
        Text(label,
            style: const TextStyle(fontSize: 11, color: Colors.white70)),
      ],
    );
  }
}

class _EndAction extends StatelessWidget {
  const _EndAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.16),
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 6),
          Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.white)),
        ],
      ),
    );
  }
}
