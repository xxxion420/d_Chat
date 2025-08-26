import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../api/talk_api.dart';
import '../services/media_cache.dart';
import '../services/image_disk_cache.dart';
import '../models/image_item.dart';

typedef LoadMoreBefore = Future<int> Function();

class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.api,
    required this.roomToken,
    required this.items,
    required this.startIndex,
    required this.headers,
    required this.myReactions,
    required this.onReactionChanged,
    this.loadMoreBefore,
  });

  final NextcloudTalkApi api;
  final String roomToken;
  final List<ImageItem> items;
  final int startIndex;
  final Map<String, String> headers;

  final Map<int, String> myReactions;
  final void Function(int messageId, String? emojiOrNull) onReactionChanged;

  final LoadMoreBefore? loadMoreBefore;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage>
    with SingleTickerProviderStateMixin {
  late final PageController _pageCtrl;
  late int _index;

  final Map<String, Uint8List?> _bytes = {};

  final TransformationController _tc = TransformationController();
  bool _pagerLocked = false;

  late final AnimationController _dismissCtrl;
  double _dragOffsetX = 0.0;
  double _viewportWidth = 1.0;

  bool _uiVisible = true;
  bool _isPinching = false;

  late final ValueNotifier<int> _pageIndexVN = ValueNotifier<int>(0);

  static const _emojiChoices = [
    '👍',
    '❤️',
    '😂',
    '😮',
    '😢',
    '🔥',
    '👏',
    '😍',
    '😡',
    '🎉',
    '🤔',
    '🤯',
    '🙏',
    '👌',
    '😎',
    '💯',
  ];

  @override
  void initState() {
    super.initState();
    _index = widget.startIndex.clamp(0, widget.items.length - 1).toInt();
    _pageCtrl = PageController(initialPage: _index);
    _pageIndexVN.value = _index;
    _preload(_index);
    _dismissCtrl =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 220),
        )..addListener(() {
          setState(() {
            _dragOffsetX = _viewportWidth * _dismissCtrl.value;
          });
        });
  }

  @override
  void dispose() {
    _pageIndexVN.dispose();
    _dismissCtrl.dispose();
    super.dispose();
  }

  Future<void> _preload(int i) async {
    if (i < 0 || i >= widget.items.length) return;
    final url = widget.items[i].url;
    if (_bytes.containsKey(url)) return;

    final cached = MediaCache.get(url);
    if (cached != null) {
      setState(() => _bytes[url] = cached);
      return;
    }

    final disk = await ImageDiskCache.get(url);
    if (disk != null) {
      MediaCache.set(url, disk);
      setState(() => _bytes[url] = disk);
      return;
    }

    try {
      final r = await http.get(Uri.parse(url), headers: widget.headers);
      if (!mounted) return;
      if (r.statusCode == 200) {
        MediaCache.set(url, r.bodyBytes);
        await ImageDiskCache.put(url, r.bodyBytes);
        setState(() => _bytes[url] = r.bodyBytes);
      } else {
        setState(() => _bytes[url] = null);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('HTTP ${r.statusCode}')));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _bytes[url] = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  void _onPageChanged(int i) async {
    setState(() => _index = i);
    _pageIndexVN.value = i;
    _tc.value = Matrix4.identity();
    _preload(i - 1);
    _preload(i + 1);

    if (i == 0 && widget.loadMoreBefore != null) {
      final before = widget.items.length;
      final added = await widget.loadMoreBefore!.call();
      if (!mounted) return;
      if (added > 0) {
        final now = widget.items.length;
        final delta = now - before;
        final newIndex = i + delta;
        _pageCtrl.jumpToPage(newIndex);
        _index = newIndex;
        _pageIndexVN.value = newIndex;
        setState(() {});
        _preload(newIndex - 1);
      }
    }
  }

  double _currentScale() => _tc.value.storage[0];

  void _onInteractionUpdate(ScaleUpdateDetails _) {
    final locked = _currentScale() > 1.01;
    if (locked != _pagerLocked) setState(() => _pagerLocked = locked);
  }

  void _onInteractionEnd(ScaleEndDetails _) {
    final locked = _currentScale() > 1.01;
    if (locked != _pagerLocked) setState(() => _pagerLocked = locked);
  }

  Future<void> _toggleReaction(String emoji) async {
    final msgId = widget.items[_index].messageId;
    final current = widget.myReactions[msgId];

    try {
      if (current == emoji) {
        await widget.api.deleteReaction(widget.roomToken, msgId, emoji);
        widget.myReactions.remove(msgId);
        widget.onReactionChanged(msgId, null);
      } else {
        if (current != null) {
          await widget.api.deleteReaction(widget.roomToken, msgId, current);
        }
        await widget.api.addReaction(widget.roomToken, msgId, emoji);
        widget.myReactions[msgId] = emoji;
        widget.onReactionChanged(msgId, emoji);
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось изменить реакцию: $e')),
      );
    }
  }

  void _openEmojiPicker() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final e in _emojiChoices)
                  ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, e),
                    child: Text(e, style: const TextStyle(fontSize: 24)),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (selected != null) _toggleReaction(selected);
  }

  void _onHDragUpdate(DragUpdateDetails d) {
    if (_pagerLocked || _isPinching || _currentScale() > 1.01) return;
    setState(
      () => _dragOffsetX = (_dragOffsetX + d.delta.dx).clamp(
        0.0,
        double.infinity,
      ),
    );
  }

  void _onHDragEnd(DragEndDetails d) {
    if (_pagerLocked || _isPinching || _currentScale() > 1.01) {
      _dismissCtrl.value = _dragOffsetX / _viewportWidth;
      _dismissCtrl.animateBack(0.0, curve: Curves.easeOutCubic);
      return;
    }
    final v = d.primaryVelocity ?? 0.0;
    final shouldClose = _dragOffsetX > _viewportWidth * 0.25 || v > 600;
    _dismissCtrl.value = _dragOffsetX / _viewportWidth;
    if (shouldClose) {
      _dismissCtrl.animateTo(1.0, curve: Curves.easeOutCubic).whenComplete(() {
        if (mounted) Navigator.of(context).maybePop();
      });
    } else {
      _dismissCtrl.animateBack(0.0, curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    _viewportWidth = w;
    final bgAlpha =
        (1.0 - (_dragOffsetX / _viewportWidth).clamp(0.0, 1.0)) * 0.6;
    final myEmoji = widget.myReactions[widget.items[_index].messageId];

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: false,
        bottom: false,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (_) => setState(() => _isPinching = true),
          onScaleEnd: (_) => setState(() => _isPinching = false),
          onHorizontalDragUpdate: _onHDragUpdate,
          onHorizontalDragEnd: _onHDragEnd,
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(color: Colors.black.withOpacity(bgAlpha)),
              ),
              Transform.translate(
                offset: Offset(_dragOffsetX, 0),
                child: PageView.builder(
                  scrollDirection: Axis.vertical,
                  controller: _pageCtrl,
                  physics: _pagerLocked
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  onPageChanged: _onPageChanged,
                  itemCount: widget.items.length,
                  itemBuilder: (context, i) {
                    final it = widget.items[i];
                    _preload(i);
                    final data = _bytes[it.url];

                    return Center(
                      child: data == null
                          ? const CircularProgressIndicator(
                              color: Colors.white70,
                            )
                          : GestureDetector(
                              onTap: () =>
                                  setState(() => _uiVisible = !_uiVisible),
                              child: InteractiveViewer(
                                transformationController: _tc,
                                clipBehavior: Clip.none,
                                minScale: 1.0,
                                maxScale: 5.0,
                                panEnabled: true,
                                scaleEnabled: true,
                                onInteractionUpdate: _onInteractionUpdate,
                                onInteractionEnd: _onInteractionEnd,
                                child: Image.memory(data, fit: BoxFit.contain),
                              ),
                            ),
                    );
                  },
                ),
              ),
              IgnorePointer(
                ignoring: !_uiVisible,
                child: AnimatedOpacity(
                  opacity: _uiVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: SafeArea(
                    child: Container(
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.black.withOpacity(0.20),
                            Colors.transparent,
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                      child: Stack(
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.arrow_back),
                              label: const Text('Назад'),
                            ),
                          ),
                          Align(
                            alignment: Alignment.center,
                            child: ValueListenableBuilder<int>(
                              valueListenable: _pageIndexVN,
                              builder: (_, idx, __) {
                                final total = widget.items.length;
                                return Text(
                                  '${idx + 1} / $total',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              IgnorePointer(
                ignoring: !_uiVisible,
                child: AnimatedOpacity(
                  opacity: _uiVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: SafeArea(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.transparent,
                              Colors.black.withOpacity(0.24),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            FilledButton.icon(
                              onPressed: () {
                                final msgId = widget.items[_index].messageId;
                                Navigator.of(context).pop(msgId);
                              },
                              icon: const Icon(Icons.textsms_outlined),
                              label: const Text('Показать в чате'),
                            ),
                            const Spacer(),
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (myEmoji != null)
                                  Container(
                                    margin: const EdgeInsets.only(bottom: 6),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black54,
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                    child: Text(
                                      myEmoji,
                                      style: const TextStyle(fontSize: 18),
                                    ),
                                  ),
                                FilledButton.icon(
                                  onPressed: _openEmojiPicker,
                                  icon: const Icon(
                                    Icons.emoji_emotions_outlined,
                                  ),
                                  label: const Text('Реакция'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
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

class _ImageItem {
  _ImageItem({required this.url, required this.name, required this.messageId});
  final String url;
  final String name;
  final int messageId;
}
