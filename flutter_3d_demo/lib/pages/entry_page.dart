import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../story/story_models.dart';
import 'generating_page.dart';
import 'interactive_story_page.dart';

/// 相册入口：回忆相册详情 + "生成 3D 回忆故事" 卡片。
/// 对应开发文档 3.1：入口放在回忆相册详情内。
class MemoryEntryPage extends StatefulWidget {
  const MemoryEntryPage({super.key});

  @override
  State<MemoryEntryPage> createState() => _MemoryEntryPageState();
}

class _MemoryEntryPageState extends State<MemoryEntryPage> {
  List<String> _photos = [];

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final keys = manifest
        .listAssets()
        .where((k) => k.startsWith('assets/thumbs/') && k.endsWith('.jpg'))
        .toList()
      ..sort();
    if (mounted) setState(() => _photos = keys);
  }

  @override
  Widget build(BuildContext context) {
    final story = demoStory;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1220),
      body: Stack(
        fit: StackFit.expand,
        children: [
          CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _buildHeader(story)),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(3, 14, 3, 190),
                sliver: SliverGrid(
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 3,
                    crossAxisSpacing: 3,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: Image.asset(
                        _photos[i],
                        fit: BoxFit.cover,
                        cacheWidth: 320,
                      ),
                    ),
                    childCount: _photos.length,
                  ),
                ),
              ),
            ],
          ),
          _buildTopBar(),
          _buildGenerateCard(story),
        ],
      ),
    );
  }

  Widget _buildHeader(StorySpec story) {
    return SizedBox(
      height: 320,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(story.coverAsset, fit: BoxFit.cover, cacheWidth: 900),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x55000000),
                  Colors.transparent,
                  Color(0xFF0B1220),
                ],
                stops: [0.0, 0.45, 1.0],
              ),
            ),
          ),
          const Positioned(
            left: 18,
            bottom: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '新疆环线',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  '632 项 · 2024.05.03 - 05.12',
                  style: TextStyle(fontSize: 13, color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new,
                    color: Colors.white, size: 20),
                onPressed: () {},
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.auto_awesome, size: 14, color: Colors.white),
                    SizedBox(width: 5),
                    Text('AI 3D 回忆故事',
                        style: TextStyle(fontSize: 12, color: Colors.white)),
                  ],
                ),
              ),
              const Spacer(),
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

  Widget _buildGenerateCard(StorySpec story) {
    return Positioned(
      left: 14,
      right: 14,
      bottom: 0,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          decoration: BoxDecoration(
            color: const Color(0xE6141D2E),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white12, width: 0.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 24,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    '新疆环线之旅',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.auto_awesome,
                      size: 18, color: Colors.blue.shade300),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                '632张照片 · 2024.05.03-12 · 全程约1322公里',
                style: TextStyle(fontSize: 12.5, color: Colors.white60),
              ),
              const SizedBox(height: 8),
              Text(
                'AI 已挑选高光照片生成 3D 回忆：可进入空间自由环视、查看旅行路线图，或生成自动播放的回忆视频。',
                style: TextStyle(
                    fontSize: 12, color: Colors.white54, height: 1.5),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF3B6DFF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(23),
                    ),
                  ),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => InteractiveStoryPage(story: story),
                      ),
                    );
                  },
                  child: const Text(
                    '进入 3D 回忆空间',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 42,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.3)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(21),
                    ),
                  ),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => GeneratingPage(story: story),
                      ),
                    );
                  },
                  child: const Text(
                    '生成回忆视频（自动播放 · 1分28秒）',
                    style: TextStyle(fontSize: 14, color: Colors.white70),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
