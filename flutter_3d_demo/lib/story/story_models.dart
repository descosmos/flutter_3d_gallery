/// 故事数据模型与 Demo Manifest。
///
/// 对应开发文档 8.1 核心对象：StoryProject / Chapter / Shot。
/// 相机运动由 Manifest 驱动，Flutter 动画只负责时间推进。
library;

enum ShotTemplate {
  dollyIn, // 推进
  parallaxPan, // 视差平移
  microOrbit, // 微环绕
  focusPull, // 焦点转移
  cardSpace, // 空间卡片（多卡环绕）
  staticParticles, // 静态增强（粒子）
  converge, // 片尾：卡片收拢成封面
}

class ShotSpec {
  const ShotSpec({
    required this.asset,
    required this.template,
    required this.duration,
    this.caption,
    this.extraAssets = const [],
    this.interactive = false,
    this.portrait = false,
  });

  /// assets/photos/ 下的完整路径
  final String asset;
  final ShotTemplate template;

  /// 秒
  final double duration;
  final String? caption;

  /// cardSpace / converge 使用的额外卡片
  final List<String> extraAssets;

  /// 互动镜头：允许拖动/倾斜产生视差
  final bool interactive;
  final bool portrait;
}

class ChapterSpec {
  const ChapterSpec({required this.title, required this.shots});

  final String title;
  final List<ShotSpec> shots;

  double get duration => shots.fold(0.0, (sum, s) => sum + s.duration);
}

class StorySpec {
  const StorySpec({
    required this.title,
    required this.dateLabel,
    required this.photoCount,
    required this.coverAsset,
    required this.chapters,
  });

  final String title;
  final String dateLabel;
  final int photoCount;
  final String coverAsset;
  final List<ChapterSpec> chapters;

  double get totalDuration =>
      chapters.fold(0.0, (sum, c) => sum + c.duration);

  /// 全局时间（秒）→ 定位到具体镜头
  ShotLocation locate(double time) {
    double t = time.clamp(0.0, totalDuration - 0.001);
    int globalShot = 0;
    for (int ci = 0; ci < chapters.length; ci++) {
      final chapter = chapters[ci];
      if (t < chapter.duration) {
        for (int si = 0; si < chapter.shots.length; si++) {
          final shot = chapter.shots[si];
          if (t < shot.duration) {
            return ShotLocation(
              chapterIndex: ci,
              shotIndex: si,
              globalShotIndex: globalShot,
              localTime: t,
              progress: t / shot.duration,
            );
          }
          t -= shot.duration;
          globalShot++;
        }
      } else {
        t -= chapter.duration;
        globalShot += chapter.shots.length;
      }
    }
    final lastChapter = chapters.length - 1;
    final lastShot = chapters.last.shots.length - 1;
    return ShotLocation(
      chapterIndex: lastChapter,
      shotIndex: lastShot,
      globalShotIndex: globalShot,
      localTime: 0,
      progress: 1,
    );
  }

  /// 每个章节的起始时间（秒），用于进度条刻度与章节跳转
  List<double> get chapterStarts {
    final starts = <double>[];
    double acc = 0;
    for (final c in chapters) {
      starts.add(acc);
      acc += c.duration;
    }
    return starts;
  }

  int get totalShots =>
      chapters.fold(0, (sum, c) => sum + c.shots.length);
}

class ShotLocation {
  const ShotLocation({
    required this.chapterIndex,
    required this.shotIndex,
    required this.globalShotIndex,
    required this.localTime,
    required this.progress,
  });

  final int chapterIndex;
  final int shotIndex;
  final int globalShotIndex;
  final double localTime;
  final double progress;
}

String _p(String name) => 'assets/photos/IMG_$name.jpg';

/// Demo 故事："新疆环线之旅"，约 88 秒，7 个章节、22 个镜头。
/// 选片来自对 photos/ 样例的分类；GPS 数据见 photo_geo.dart。
final demoStory = StorySpec(
  title: '新疆环线之旅',
  dateLabel: '2024年5月3日-12日',
  photoCount: 632,
  coverAsset: _p('20240509_102226'),
  chapters: [
    ChapterSpec(title: '开场', shots: [
      ShotSpec(
        asset: _p('20240509_102226'),
        template: ShotTemplate.dollyIn,
        duration: 5,
      ),
      ShotSpec(
        asset: _p('20240509_152417'),
        template: ShotTemplate.parallaxPan,
        duration: 4,
        caption: '赛里木湖的风，吹散了所有的疲惫',
      ),
    ]),
    ChapterSpec(title: '抵达', shots: [
      ShotSpec(
        asset: _p('20240503_180134'),
        template: ShotTemplate.parallaxPan,
        duration: 4,
        caption: '从公路驶向赛里木湖',
      ),
      ShotSpec(
        asset: _p('20240507_105118'),
        template: ShotTemplate.dollyIn,
        duration: 4,
        portrait: true,
      ),
      ShotSpec(
        asset: _p('20240509_101622'),
        template: ShotTemplate.parallaxPan,
        duration: 4.5,
        caption: '雪山与湖面在眼前缓缓展开',
      ),
    ]),
    ChapterSpec(title: '湖畔', shots: [
      ShotSpec(
        asset: _p('20240504_154139'),
        template: ShotTemplate.focusPull,
        duration: 3.5,
      ),
      ShotSpec(
        asset: _p('20240504_154144'),
        template: ShotTemplate.parallaxPan,
        duration: 3.5,
      ),
      ShotSpec(
        asset: _p('20240504_154214'),
        template: ShotTemplate.dollyIn,
        duration: 3.5,
        caption: '湖水湛蓝如宝石',
      ),
      ShotSpec(
        asset: _p('20240504_161223'),
        template: ShotTemplate.focusPull,
        duration: 3,
      ),
      ShotSpec(
        asset: _p('20240504_183555'),
        template: ShotTemplate.parallaxPan,
        duration: 3.5,
      ),
    ]),
    ChapterSpec(title: '人物', shots: [
      ShotSpec(
        asset: _p('20240509_114359'),
        template: ShotTemplate.microOrbit,
        duration: 4,
        interactive: true,
        caption: '旅途中的笑容与风景，在空间中一层层展开',
      ),
      ShotSpec(
        asset: _p('20240505_151315'),
        template: ShotTemplate.microOrbit,
        duration: 4,
        interactive: true,
        portrait: true,
      ),
      ShotSpec(
        asset: _p('20240505_103326'),
        template: ShotTemplate.dollyIn,
        duration: 3.5,
      ),
      ShotSpec(
        asset: _p('20240505_104201'),
        template: ShotTemplate.microOrbit,
        duration: 3.5,
        interactive: true,
      ),
      ShotSpec(
        asset: _p('20240509_114401'),
        template: ShotTemplate.focusPull,
        duration: 3,
      ),
    ]),
    ChapterSpec(title: '雪山', shots: [
      ShotSpec(
        asset: _p('20240505_103642'),
        template: ShotTemplate.cardSpace,
        duration: 5,
        extraAssets: [_p('20240506_200631'), _p('20240506_180648')],
        caption: '雪山环绕，天地辽阔',
      ),
      ShotSpec(
        asset: _p('20240507_092618'),
        template: ShotTemplate.cardSpace,
        duration: 5,
        extraAssets: [_p('20240507_092621'), _p('20240506_172220')],
      ),
      ShotSpec(
        asset: _p('20240507_093002'),
        template: ShotTemplate.staticParticles,
        duration: 4,
      ),
    ]),
    ChapterSpec(title: '尾声', shots: [
      ShotSpec(
        asset: _p('20240504_232713'),
        template: ShotTemplate.staticParticles,
        duration: 3.5,
        caption: '夜色温柔，收藏这片刻',
      ),
      ShotSpec(
        asset: _p('20240507_222156'),
        template: ShotTemplate.staticParticles,
        duration: 3,
      ),
      ShotSpec(
        asset: _p('20240507_222811'),
        template: ShotTemplate.dollyIn,
        duration: 3.5,
      ),
    ]),
    ChapterSpec(title: '片尾', shots: [
      ShotSpec(
        asset: _p('20240509_102226'),
        template: ShotTemplate.converge,
        duration: 8,
        extraAssets: [
          _p('20240509_114359'),
          _p('20240504_154214'),
          _p('20240506_180648'),
          _p('20240509_101622'),
          _p('20240504_232713'),
        ],
      ),
    ]),
  ],
);
