import 'package:flutter/material.dart';

import '../player/story_player_page.dart';
import '../gpu/story_scene.dart';
import '../story/story_models.dart';

/// AI 分析与生成页：3D 浮动照片卡 + 进度环 + 阶段清单。
/// 对应开发文档 3.2：进度映射为可理解的阶段，而不是单一百分比。
class GeneratingPage extends StatefulWidget {
  const GeneratingPage({super.key, required this.story});

  final StorySpec story;

  @override
  State<GeneratingPage> createState() => _GeneratingPageState();
}

class _GeneratingPageState extends State<GeneratingPage>
    with TickerProviderStateMixin {
  late final AnimationController _spin;
  late final AnimationController _progress;
  bool _navigated = false;

  static const _stages = [
    '照片筛选与去重',
    '人物与场景识别',
    '生成深度与空间分层',
    '编排镜头与故事节奏',
    '生成低清预览',
  ];

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
    _progress = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 6800),
    )
      ..addListener(() => setState(() {}))
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && !_navigated) {
          _navigated = true;
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => StoryPlayerPage(story: widget.story),
            ),
          );
        }
      })
      ..forward();
  }

  @override
  void dispose() {
    _spin.dispose();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _progress.value;
    return Scaffold(
      backgroundColor: const Color(0xFF070B14),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new,
                        color: Colors.white, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Expanded(
                    child: Center(
                      child: Text('生成 3D 回忆故事',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Text(
              _stageHint(p),
              style: const TextStyle(fontSize: 13, color: Colors.white54),
            ),
            const SizedBox(height: 8),
            Expanded(child: _buildCarousel()),
            _buildProgressRing(p),
            const SizedBox(height: 26),
            _buildChecklist(p),
            const SizedBox(height: 16),
            Text(
              '预计还需 ${((1 - p) * 32).ceil()} 秒',
              style: const TextStyle(fontSize: 12, color: Colors.white38),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  String _stageHint(double p) {
    if (p < 0.2) return '正在挑选精彩照片';
    if (p < 0.4) return '正在识别人物与场景';
    if (p < 0.62) return '正在生成空间层次';
    if (p < 0.85) return '正在编排镜头与故事节奏';
    return '正在生成可播放预览';
  }

  Widget _buildCarousel() => AnimatedBuilder(
    animation: _spin,
    builder: (context, _) => GpuStoryScene(story: widget.story,
      time: _spin.value * 8, parallax: Offset.zero),
  );

  Widget _buildProgressRing(double p) {
    return SizedBox(
      width: 92,
      height: 92,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 92,
            height: 92,
            child: CircularProgressIndicator(
              value: p,
              strokeWidth: 5,
              backgroundColor: Colors.white12,
              valueColor:
                  const AlwaysStoppedAnimation(Color(0xFF4D7CFF)),
              strokeCap: StrokeCap.round,
            ),
          ),
          Text(
            '${(p * 100).round()}%',
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChecklist(double p) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 56),
      child: Column(
        children: [
          for (int i = 0; i < _stages.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  _stageIcon(p, i),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _stages[i],
                      style: TextStyle(
                        fontSize: 14,
                        color: p > i / _stages.length
                            ? Colors.white
                            : Colors.white38,
                      ),
                    ),
                  ),
                  Text(
                    p >= (i + 1) / _stages.length
                        ? '完成'
                        : (p > i / _stages.length ? '处理中' : '等待'),
                    style: TextStyle(
                      fontSize: 12,
                      color: p >= (i + 1) / _stages.length
                          ? Colors.white54
                          : (p > i / _stages.length
                              ? const Color(0xFF4D7CFF)
                              : Colors.white24),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _stageIcon(double p, int i) {
    if (p >= (i + 1) / _stages.length) {
      return const Icon(Icons.check_circle, size: 20, color: Color(0xFF4ADE80));
    }
    if (p > i / _stages.length) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(Color(0xFF4D7CFF)),
        ),
      );
    }
    return Icon(Icons.circle_outlined,
        size: 20, color: Colors.white.withValues(alpha: 0.2));
  }
}
