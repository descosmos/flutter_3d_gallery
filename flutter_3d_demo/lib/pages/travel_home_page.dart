import 'package:flutter/material.dart';

import '../gpu/globe_page.dart';
import '../gpu/photo_preview.dart';
import '../photos/local_photo_library.dart';
import '../photos/photo_source.dart';
import 'entry_page.dart';
import 'interactive_story_page.dart';

class TravelHomePage extends StatefulWidget {
  const TravelHomePage({super.key, this.library});
  final LocalPhotoLibrary? library;

  @override
  State<TravelHomePage> createState() => _TravelHomePageState();
}

class _TravelHomePageState extends State<TravelHomePage> {
  late final LocalPhotoLibrary _library = widget.library ?? LocalPhotoLibrary();

  @override
  void initState() {
    super.initState();
    _library.load();
  }

  @override
  void dispose() {
    if (widget.library == null) _library.dispose();
    super.dispose();
  }

  void _open(bool globe) {
    final selected = _library.selected;
    if (selected.isEmpty || _library.busy) return;
    final story = storyFromPhotos(selected);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => globe
            ? GpuGlobePage(
                focus: selected.first.point,
                story: story,
                photos: story.mapPhotos!.entries.toList(),
              )
            : InteractiveStoryPage(story: story),
      ),
    );
  }

  Future<void> _remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('移除 ${_library.selected.length} 张照片？'),
        content: const Text('仅移除本应用保存的副本，手机相册中的原图会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _library.removeSelected();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _library,
    builder: (context, _) {
      final selected = _library.selected;
      final enabled = selected.isNotEmpty && !_library.busy;
      return Scaffold(
        backgroundColor: const Color(0xFF0B1220),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0B1220),
          title: const Text(
            '旅行相册',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          actions: [
            TextButton.icon(
              key: const ValueKey('open-demo'),
              onPressed: _library.busy
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const MemoryEntryPage(),
                      ),
                    ),
              icon: const Icon(Icons.auto_awesome_outlined, size: 17),
              label: const Text('示例模版'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF1C3655), Color(0xFF172033)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.travel_explore,
                            color: Color(0xFF9DCCFF),
                            size: 36,
                          ),
                          const SizedBox(height: 18),
                          const Text(
                            '我的旅行照片',
                            style: TextStyle(
                              fontSize: 25,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '把沿途的风景，带进回忆空间。',
                            style: TextStyle(
                              color: Colors.white70,
                              height: 1.6,
                            ),
                          ),
                          const SizedBox(height: 22),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              key: const ValueKey('pick-local-photos'),
                              onPressed: _library.busy ? null : _library.pick,
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 15,
                                ),
                              ),
                              icon: const Icon(
                                Icons.add_photo_alternate_outlined,
                              ),
                              label: Text(
                                _library.photos.isEmpty ? '选择本机照片' : '添加本机照片',
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '支持多选 · 仅展示带位置信息的照片',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white60,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_library.busy) ...[
                      const SizedBox(height: 16),
                      LinearProgressIndicator(
                        value: _library.progress == null
                            ? null
                            : _library.progress!.$1 / _library.progress!.$2,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _library.progress == null
                            ? (_library.importing
                                  ? '请选择照片，完成后返回应用…'
                                  : '正在读取照片…')
                            : '正在导入 ${_library.progress!.$1} / ${_library.progress!.$2} 张',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                    if (_library.notice != null || _library.error != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        _library.error ?? _library.notice!,
                        style: TextStyle(
                          color: _library.error == null
                              ? Colors.white70
                              : const Color(0xFFFFB4AB),
                          height: 1.5,
                        ),
                      ),
                      if (_library.error != null)
                        TextButton(
                          onPressed: _library.busy ? null : _library.load,
                          child: const Text('重新读取'),
                        ),
                    ],
                    if (_library.photos.isNotEmpty) ...[
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '已选 ${selected.length} / ${_library.photos.length} 张',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: _library.busy
                                ? null
                                : () => _library.select(
                                    selected.length == _library.photos.length
                                        ? {}
                                        : _library.photos
                                              .map((p) => p.id)
                                              .toSet(),
                                  ),
                            child: Text(
                              selected.length == _library.photos.length
                                  ? '取消全选'
                                  : '全选',
                            ),
                          ),
                          IconButton(
                            tooltip: '移除所选照片',
                            onPressed: enabled ? _remove : null,
                            icon: const Icon(Icons.delete_outline, size: 21),
                          ),
                        ],
                      ),
                      const Text(
                        '点按选择 · 长按预览 · 已导入照片保存在本机',
                        style: TextStyle(fontSize: 12, color: Colors.white54),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_library.photos.isEmpty && !_library.busy)
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(32, 28, 32, 36),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    children: [
                      Icon(
                        Icons.photo_library_outlined,
                        size: 42,
                        color: Colors.white24,
                      ),
                      SizedBox(height: 14),
                      Text(
                        '从一段新的旅程开始',
                        style: TextStyle(fontSize: 17, color: Colors.white70),
                      ),
                      SizedBox(height: 8),
                      Text(
                        '选择照片后，即可进入回忆空间和照片地球。\n也可以先打开右上角的示例模版。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.8,
                          color: Colors.white38,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 7,
                  mainAxisSpacing: 7,
                ),
                itemCount: _library.photos.length,
                itemBuilder: (context, i) {
                  final photo = _library.photos[i];
                  return Semantics(
                    label: '${photo.name}，${photo.selected ? '已选择' : '未选择'}',
                    selected: photo.selected,
                    button: true,
                    child: GestureDetector(
                      key: ValueKey('local-photo-${photo.id}'),
                      onTap: _library.busy
                          ? null
                          : () {
                              final ids = selected.map((p) => p.id).toSet();
                              if (photo.selected) {
                                ids.remove(photo.id);
                              } else {
                                ids.add(photo.id);
                              }
                              _library.select(ids);
                            },
                      onLongPress: _library.busy
                          ? null
                          : () => showPhotoPreview(context, photo.path),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image(
                              image: photoImageProvider(
                                photoThumbnail(photo.path),
                              ),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  const Icon(Icons.broken_image_outlined),
                            ),
                            if (!photo.selected)
                              const ColoredBox(color: Color(0x880B1220)),
                            Positioned(
                              right: 6,
                              top: 6,
                              child: Icon(
                                photo.selected
                                    ? Icons.check_circle
                                    : Icons.circle_outlined,
                                color: photo.selected
                                    ? const Color(0xFF9DCCFF)
                                    : Colors.white70,
                                shadows: const [
                                  Shadow(blurRadius: 5, color: Colors.black),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('open-local-space'),
                    onPressed: enabled ? () => _open(false) : null,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    icon: const Icon(Icons.view_in_ar_outlined, size: 20),
                    label: const Text('回忆空间'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('open-local-globe'),
                    onPressed: enabled ? () => _open(true) : null,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    icon: const Icon(Icons.public, size: 20),
                    label: const Text('3D 照片地球'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
