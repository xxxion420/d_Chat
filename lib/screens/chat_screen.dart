import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;

import '../api/talk_api.dart';
import '../services/talk_cache.dart';
import '../services/playback_hub.dart';
import '../widgets/file_bubble.dart';
import '../widgets/reply_widgets.dart';
import '../widgets/size_reporter.dart';
import 'image_viewer_page.dart';
import '../models/image_item.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.api, required this.room});
  final NextcloudTalkApi api;
  final NcRoom room;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scroll = ScrollController();
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _recorder = AudioRecorder();

  final Map<int, double> _itemHeights = {};
  final Map<int, int> _idToIndex = {};
  final Map<int, String> _myReactions = {};
  final Map<int, GlobalKey> _msgKeys = {};

  double _inputBarHeight = 56;
  double _replyBarHeight = 0.0;
  double _recordBarHeight = 0.0;

  List<NcMessage> _messages = [];
  bool _loading = false;
  bool _loadingOlder = false;
  int? _lastKnownIdNewer;
  int? _olderPageOffsetId;
  Timer? _poll;
  bool _isRecording = false;
  String? _recordError;
  String? _currentRecPath;

  bool _showDownBtn = false;

  StreamSubscription<Amplitude>? _ampSub;
  double _recAmp = 0.0;

  NcMessage? _replyTarget;
  bool _scrolledToEndOnce = false;

  bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final K k in a.keys) {
      if (!b.containsKey(k) || a[k] != b[k]) return false;
    }
    return true;
  }

  bool _patchReactionsFromServer(Iterable<NcMessage> incoming) {
    if (_messages.isEmpty) return false;

    final idxById = <int, int>{};
    for (var i = 0; i < _messages.length; i++) {
      idxById[_messages[i].id] = i;
    }

    var changed = false;
    for (final srv in incoming) {
      final i = idxById[srv.id];
      if (i == null) continue;
      final local = _messages[i];

      final sameMap = _mapEquals(local.reactions, srv.reactions);
      final sameSelf =
          local.reactionsSelf.length == srv.reactionsSelf.length &&
          local.reactionsSelf.toSet().containsAll(srv.reactionsSelf);

      if (!sameMap || !sameSelf) {
        _messages[i] = NcMessage(
          id: local.id,
          actorId: local.actorId,
          actorDisplayName: local.actorDisplayName,
          message: local.message,
          timestamp: local.timestamp,
          isFile: local.isFile,
          filePath: local.filePath,
          fileId: local.fileId,
          fileMime: local.fileMime,
          messageType: local.messageType,
          isSystemLike: local.isSystemLike,
          parentId: local.parentId,
          parentAuthor: local.parentAuthor,
          parentText: local.parentText,
          parentIsFile: local.parentIsFile,
          parentFileName: local.parentFileName,
          reactions: Map<String, int>.from(srv.reactions),
          reactionsSelf: List<String>.from(srv.reactionsSelf),
        );
        changed = true;
      }
    }
    return changed;
  }

  @override
  void initState() {
    super.initState();

    () async {
      final cached = await TalkCache.loadTail(widget.room.token);
      if (mounted && cached != null && cached.isNotEmpty) {
        setState(() {
          _messages = _mergeAndSort(_messages, cached);
          _idToIndex
            ..clear()
            ..addEntries(
              _visibleMessages.asMap().entries.map(
                (e) => MapEntry(e.value.id, e.key),
              ),
            );
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
        _scrolledToEndOnce = true;
      }
      await _load(initial: true);
    }();

    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _load());
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final farFromBottom =
        _scroll.position.maxScrollExtent - _scroll.position.pixels > 200;
    if (_showDownBtn != farFromBottom && mounted) {
      setState(() => _showDownBtn = farFromBottom);
    }
    if (_scroll.position.pixels <= 48 && !_loadingOlder) {
      _loadOlder();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _input.dispose();
    _inputFocus.dispose();
    _ampSub?.cancel();
    super.dispose();
  }

  Future<void> _load({bool initial = false}) async {
    if (_loading) return;
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final page = await widget.api.fetchMessagesPaged(
        widget.room.token,
        lookIntoFuture: initial ? 0 : 1,
        lastKnownId: _lastKnownIdNewer,
        limit: initial ? 60 : 120,
        setReadMarker: 0,
        markNotificationsAsRead: 0,
      );
      if (!mounted) return;
      final res = page.messages;
      if (res.isNotEmpty) {
        setState(() {
          _messages = _mergeAndSort(_messages, res);
          _idToIndex
            ..clear()
            ..addEntries(
              _visibleMessages.asMap().entries.map(
                (e) => MapEntry(e.value.id, e.key),
              ),
            );
          _lastKnownIdNewer = _messages.isNotEmpty
              ? _messages.last.id
              : _lastKnownIdNewer;
          _olderPageOffsetId ??= page.lastGiven;
          for (final m in _messages) {
            if (m.reactionsSelf.isNotEmpty) {
              _myReactions[m.id] = m.reactionsSelf.first;
            } else {
              _myReactions.remove(m.id);
            }
          }
        });

        final patched = _patchReactionsFromServer(res);
        if (patched && mounted) {
          setState(() {});
        }

        if (initial && !_scrolledToEndOnce) {
          _scrolledToEndOnce = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients)
              _scroll.jumpTo(_scroll.position.maxScrollExtent);
          });
        }

        await TalkCache.saveTailWithMedia(
          widget.api,
          widget.room.token,
          _messages,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка загрузки сообщений: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder) return;
    if (_olderPageOffsetId == null) return;
    setState(() => _loadingOlder = true);
    final anchorId = _visibleMessages.isNotEmpty
        ? _visibleMessages.first.id
        : null;

    try {
      final page = await widget.api.fetchMessagesPaged(
        widget.room.token,
        lookIntoFuture: 0,
        lastKnownId: _olderPageOffsetId,
        limit: 100,
        setReadMarker: 0,
        markNotificationsAsRead: 0,
      );
      if (!mounted) return;

      if (page.messages.isNotEmpty) {
        setState(() {
          _messages = _mergeAndSort(_messages, page.messages);
          _idToIndex
            ..clear()
            ..addEntries(
              _visibleMessages.asMap().entries.map(
                (e) => MapEntry(e.value.id, e.key),
              ),
            );
          _olderPageOffsetId = page.lastGiven;
        });

        if (anchorId != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToMessageById(anchorId, jump: true);
          });
        }
        await TalkCache.saveTailWithMedia(
          widget.api,
          widget.room.token,
          _messages,
        );
      } else {
        _olderPageOffsetId = page.lastGiven ?? _olderPageOffsetId;
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('История: $e')));
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<bool> _loadOlderForTarget() async {
    if (_olderPageOffsetId == null || _loadingOlder) return false;
    setState(() => _loadingOlder = true);
    final anchorId = _visibleMessages.isNotEmpty
        ? _visibleMessages.first.id
        : null;
    try {
      final page = await widget.api.fetchMessagesPaged(
        widget.room.token,
        lookIntoFuture: 0,
        lastKnownId: _olderPageOffsetId,
        limit: 120,
        setReadMarker: 0,
        markNotificationsAsRead: 0,
      );
      if (!mounted) return false;
      if (page.messages.isNotEmpty) {
        setState(() {
          _messages = _mergeAndSort(_messages, page.messages);
          _idToIndex
            ..clear()
            ..addEntries(
              _visibleMessages.asMap().entries.map(
                (e) => MapEntry(e.value.id, e.key),
              ),
            );
          _olderPageOffsetId = page.lastGiven;
        });
        if (anchorId != null) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToMessageById(anchorId, jump: true),
          );
        }
        await TalkCache.saveTailWithMedia(
          widget.api,
          widget.room.token,
          _messages,
        );
        return true;
      } else {
        _olderPageOffsetId = page.lastGiven ?? _olderPageOffsetId;
        return false;
      }
    } catch (_) {
      return false;
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  List<NcMessage> _mergeAndSort(List<NcMessage> a, List<NcMessage> b) {
    final map = {for (final m in a) m.id: m};
    for (final m in b) {
      map[m.id] = m;
    }
    final list = map.values.toList()
      ..sort((x, y) => x.timestamp.compareTo(y.timestamp));
    return list;
  }

  List<NcMessage> get _visibleMessages =>
      _messages.where((m) => !m.isSystemLike).toList(growable: false);

  Future<void> _sendText() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final replyId = _replyTarget?.id;
    _input.clear();
    setState(() => _replyTarget = null);
    try {
      await widget.api.sendMessage(widget.room.token, text, replyTo: replyId);
      await _load();
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Не удалось отправить: $e')));
      }
    }
  }

  Future<void> _sendPickedFile(File file, {String? overrideName}) async {
    try {
      final replyId = _replyTarget?.id;
      setState(() => _replyTarget = null);
      await widget.api.sendFileToChat(
        widget.room.token,
        file,
        overrideName: overrideName,
        replyTo: replyId,
      );
      await _load();
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось отправить файл: $e')),
        );
      }
    }
  }

  Future<void> _sendVoiceFile(File file) async {
    try {
      final replyId = _replyTarget?.id;
      setState(() => _replyTarget = null);
      await widget.api.sendFileToChat(
        widget.room.token,
        file,
        overrideName: 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
        replyTo: replyId,
        messageType: 'voice-message',
      );
      await _load();
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось отправить голосовое: $e')),
        );
      }
    }
  }

  Future<void> _pickFromGallery({
    required bool image,
    required bool video,
  }) async {
    final picker = ImagePicker();
    final source = ImageSource.gallery;
    if (image && !video) {
      final x = await picker.pickImage(
        source: source,
        maxWidth: 4096,
        maxHeight: 4096,
      );
      if (x != null) await _sendPickedFile(File(x.path));
    } else if (!image && video) {
      final x = await picker.pickVideo(
        source: source,
        maxDuration: const Duration(minutes: 10),
      );
      if (x != null) await _sendPickedFile(File(x.path));
    }
  }

  Future<void> _captureCamera({
    required bool image,
    required bool video,
  }) async {
    final picker = ImagePicker();
    final source = ImageSource.camera;
    if (image && !video) {
      final x = await picker.pickImage(
        source: source,
        imageQuality: 90,
        maxWidth: 4096,
        maxHeight: 4096,
      );
      if (x != null) await _sendPickedFile(File(x.path));
    } else if (!image && video) {
      final x = await picker.pickVideo(
        source: source,
        maxDuration: const Duration(minutes: 5),
      );
      if (x != null) await _sendPickedFile(File(x.path));
    }
  }

  Future<void> _pickAnyFile() async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: false);
    if (res != null && res.files.single.path != null) {
      await _sendPickedFile(
        File(res.files.single.path!),
        overrideName: res.files.single.name,
      );
    }
  }

  Future<void> _toggleRecord() async {
    if (_isRecording) {
      try {
        final path = await _recorder.stop();
        _ampSub?.cancel();
        _recAmp = 0.0;
        if (!mounted) return;
        setState(() => _isRecording = false);
        final f = path ?? _currentRecPath;
        _currentRecPath = null;
        if (f != null) {
          await _sendVoiceFile(File(f));
        }
      } catch (e) {
        if (!mounted) return;
        setState(() => _recordError = e.toString());
      }
      return;
    }

    try {
      _recordError = null;
      final ok = await _recorder.hasPermission();
      if (!mounted) return;
      if (!ok) {
        setState(() => _recordError = 'Нет разрешения на запись');
        return;
      }

      await PlaybackHub.pauseAll();
      await Future.delayed(const Duration(milliseconds: 200));

      final dir = Directory.systemTemp.path;
      final fpath = p.join(
        dir,
        'rec_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      _currentRecPath = fpath;

      final cfg = const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: 44100,
        numChannels: 1,
      );

      await _recorder.start(cfg, path: fpath);
      _ampSub?.cancel();
      _ampSub = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 80))
          .listen((a) {
            final db = a.current;
            double level = (db + 45.0) / 45.0;
            level = level.clamp(0.0, 1.0);
            if (mounted) setState(() => _recAmp = level);
          });
      if (!mounted) return;
      setState(() => _isRecording = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _recordError = e.toString());
    }
  }

  Future<void> _cancelRecord() async {
    try {
      final path = await _recorder.stop();
      _ampSub?.cancel();
      _recAmp = 0.0;
      final f = path ?? _currentRecPath;
      _currentRecPath = null;
      if (f != null) {
        final file = File(f);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _isRecording = false);
  }

  void _openAttachSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Wrap(
            children: [
              _attachTile(Icons.image_outlined, 'Фото из галереи', () {
                Navigator.pop(context);
                _pickFromGallery(image: true, video: false);
              }),
              _attachTile(Icons.photo_camera_outlined, 'Сделать фото', () {
                Navigator.pop(context);
                _captureCamera(image: true, video: false);
              }),
              _attachTile(Icons.videocam_outlined, 'Видео из галереи', () {
                Navigator.pop(context);
                _pickFromGallery(image: false, video: true);
              }),
              _attachTile(Icons.videocam, 'Снять видео', () {
                Navigator.pop(context);
                _captureCamera(image: false, video: true);
              }),
              _attachTile(Icons.attach_file, 'Файл', () {
                Navigator.pop(context);
                _pickAnyFile();
              }),
              ListTile(
                leading: Icon(
                  _isRecording ? Icons.stop_circle : Icons.mic_none,
                ),
                title: Text(
                  _isRecording ? 'Остановить запись' : 'Голосовое сообщение',
                ),
                onTap: () {
                  Navigator.pop(context);
                  _toggleRecord();
                },
                subtitle: _recordError != null
                    ? Text(
                        _recordError!,
                        style: const TextStyle(color: Colors.red),
                      )
                    : null,
              ),
            ],
          ),
        );
      },
    );
  }

  ListTile _attachTile(IconData icon, String title, VoidCallback onTap) {
    return ListTile(leading: Icon(icon), title: Text(title), onTap: onTap);
  }

  Future<void> _openImageViewer(int startIndex, List<ImageItem> items) async {
    final result = await Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (_, __, ___) => ImageViewerPage(
          api: widget.api,
          roomToken: widget.room.token,
          items: items,
          startIndex: startIndex,
          headers: widget.api.authHeaders,
          myReactions: Map<int, String>.from(_myReactions),
          onReactionChanged: (messageId, emojiOrNull) {
            setState(() {
              if (emojiOrNull == null) {
                _myReactions.remove(messageId);
              } else {
                _myReactions[messageId] = emojiOrNull;
              }
            });
          },
          loadMoreBefore: () async {
            final beforeLen = items.length;
            final got = await _loadOlderForTarget();
            if (got) {
              items
                ..clear()
                ..addAll(
                  _visibleMessages
                      .where(
                        (m) =>
                            m.isFile &&
                            (m.fileMime?.startsWith('image/') ?? false) &&
                            m.filePath != null,
                      )
                      .map(
                        (m) => ImageItem(
                          url: widget.api.webdavFileUrl(m.filePath!),
                          name: p.basename(m.filePath!),
                          messageId: m.id,
                        ),
                      ),
                );
            }
            return items.length - beforeLen;
          },
        ),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
    if (result is int) {
      await _scrollToMessageEnsureLoaded(result);
    }
  }

  double _estimateOffsetForIndex(int targetIndex) {
    double offset = 0;
    final visible = _visibleMessages;
    for (int i = 0; i < targetIndex && i < visible.length; i++) {
      final id = visible[i].id;
      offset += _itemHeights[id] ?? 80.0;
    }
    return offset;
  }

  double _extraBottomPadding() {
    final pad = MediaQuery.of(context).padding.bottom;
    return _inputBarHeight + _replyBarHeight + _recordBarHeight + pad;
  }

  double? _offsetToStickBottom(GlobalKey key) {
    if (!_scroll.hasClients) return null;
    final ctx = key.currentContext;
    final render = ctx?.findRenderObject();
    if (render == null) return null;

    final viewport = RenderAbstractViewport.of(render);
    if (viewport == null) return null;

    final reveal = viewport.getOffsetToReveal(render, 1.0).offset;
    final correction = _extraBottomPadding();
    final target = (reveal - correction)
        .clamp(0.0, _scroll.position.maxScrollExtent)
        .toDouble();
    return target;
  }

  Future<void> _stickMessageAtInput(int messageId, {bool jump = false}) async {
    final key = _msgKeys[messageId];
    if (key == null) return;
    double? off = _offsetToStickBottom(key);
    if (off == null) return;

    if (jump) {
      _scroll.jumpTo(off);
    } else {
      await _scroll.animateTo(
        off,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    }
    for (int i = 0; i < 2; i++) {
      await Future.delayed(const Duration(milliseconds: 60));
      off = _offsetToStickBottom(key);
      if (off != null) _scroll.jumpTo(off);
    }
  }

  Future<void> _scrollToMessageEnsureLoaded(int messageId) async {
    int guard = 0;
    while (!_idToIndex.containsKey(messageId) &&
        _olderPageOffsetId != null &&
        guard < 25) {
      final got = await _loadOlderForTarget();
      if (!got) break;
      guard++;
    }
    if (_idToIndex.containsKey(messageId)) {
      await _stickMessageAtInput(messageId, jump: true);
    }
  }

  void _scrollToMessageById(int messageId, {bool jump = false}) {
    final targetIndex = _idToIndex[messageId];
    if (targetIndex == null || !_scroll.hasClients) return;
    final offset = _estimateOffsetForIndex(
      targetIndex,
    ).clamp(0.0, _scroll.position.maxScrollExtent).toDouble();
    if (jump) {
      _scroll.jumpTo(offset);
    } else {
      _scroll.animateTo(
        offset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  bool _isKeyboardVisible() => MediaQuery.of(context).viewInsets.bottom > 0;

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    void go() {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }

    go();
    WidgetsBinding.instance.addPostFrameCallback((_) => go());
  }

  Future<void> _showEditAgeDialog() async {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Редактирование недоступно'),
        content: const Text(
          'Сообщение можно редактировать только в течение 6 часов после отправки.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Понятно'),
          ),
        ],
      ),
    );
  }

  void _openMessageMenu(NcMessage m) async {
    final me = widget.api.username;
    final canEdit = !m.isFile && (m.actorId == me);
    final canDelete = (m.actorId == me);
    final hasText = (m.message?.isNotEmpty ?? false);

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.reply_outlined),
                title: const Text('Ответить'),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _replyTarget = m);
                  FocusScope.of(context).requestFocus(_inputFocus);
                  HapticFeedback.mediumImpact();
                },
              ),
              if (canEdit)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Редактировать'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final nowSec =
                        DateTime.now().millisecondsSinceEpoch ~/ 1000;
                    if (nowSec - m.timestamp >= 6 * 3600) {
                      await _showEditAgeDialog();
                    } else {
                      _openEditDialog(m);
                    }
                  },
                ),
              if (hasText)
                ListTile(
                  leading: const Icon(Icons.copy_all_outlined),
                  title: const Text('Скопировать текст'),
                  onTap: () async {
                    await Clipboard.setData(
                      ClipboardData(text: m.message ?? ''),
                    );
                    if (mounted) {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Скопировано')),
                      );
                    }
                  },
                ),
              ListTile(
                leading: const Icon(Icons.forward_outlined),
                title: const Text('Переслать в другой чат'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openForwardSheet(m);
                },
              ),
              if (canDelete)
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: const Text(
                    'Удалить',
                    style: TextStyle(color: Colors.red),
                  ),
                  onTap: () async {
                    Navigator.pop(ctx);
                    try {
                      await widget.api.deleteMessage(widget.room.token, m.id);
                      setState(() {
                        _messages.removeWhere((x) => x.id == m.id);
                        _idToIndex.remove(m.id);
                      });
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Не удалось удалить: $e')),
                      );
                    }
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  void _openEditDialog(NcMessage m) {
    final ctrl = TextEditingController(text: m.message ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Редактировать сообщение'),
        content: TextField(
          controller: ctrl,
          maxLines: null,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () async {
              final newText = ctrl.text.trim();
              Navigator.pop(ctx);
              try {
                await widget.api.editMessage(widget.room.token, m.id, newText);
                await _load();
              } catch (e) {
                final s = e.toString();
                if (s.contains('"error":"age"') ||
                    s.contains('error":"age') ||
                    s.contains('age"')) {
                  await _showEditAgeDialog();
                } else {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Не удалось редактировать: $e')),
                  );
                }
              }
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  void _openForwardSheet(NcMessage m) async {
    final rooms = await widget.api.listRooms();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Выберите чат')),
              for (final r in rooms.where((r) => r.token != widget.room.token))
                ListTile(
                  leading: const Icon(Icons.chat_outlined),
                  title: Text(r.displayName.isEmpty ? r.token : r.displayName),
                  onTap: () async {
                    Navigator.pop(ctx);
                    try {
                      if (m.isFile && m.filePath != null) {
                        await widget.api.shareExistingFileToChat(
                          r.token,
                          m.filePath!,
                        );
                      } else if ((m.message?.isNotEmpty ?? false)) {
                        await widget.api.sendMessage(r.token, m.message!);
                      } else {
                        throw 'Пустое сообщение';
                      }
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Переслано')),
                        );
                      }
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Не удалось переслать: $e')),
                      );
                    }
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('dd.MM.yyyy HH:mm');
    final me = widget.api.username;

    final msgs = _visibleMessages;

    final imageItems = <ImageItem>[];
    for (final m in msgs) {
      final isImg = m.isFile && (m.fileMime?.startsWith('image/') ?? false);
      if (isImg && m.filePath != null) {
        imageItems.add(
          ImageItem(
            url: widget.api.webdavFileUrl(m.filePath!),
            name: p.basename(m.filePath!),
            messageId: m.id,
          ),
        );
      }
    }

    final titleText = widget.room.displayName.isEmpty
        ? widget.room.token
        : widget.room.displayName;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            // мини-аватар можно повторно использовать из списка комнат при желании
            CircleAvatar(
              radius: 16,
              child: Text(
                titleText.isEmpty
                    ? '?'
                    : titleText.characters.first.toUpperCase(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(titleText, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: NotificationListener<ScrollUpdateNotification>(
                  onNotification: (n) {
                    if (n.dragDetails != null &&
                        (n.scrollDelta ?? 0) < 0 &&
                        _isKeyboardVisible()) {
                      FocusScope.of(context).unfocus();
                    }
                    return false;
                  },
                  child: ListView.builder(
                    controller: _scroll,
                    itemCount: msgs.length,
                    itemBuilder: (context, i) {
                      final m = msgs[i];
                      final isMe = (m.actorId == me);

                      int? imageIndex;
                      if (m.isFile &&
                          (m.fileMime?.startsWith('image/') ?? false) &&
                          m.filePath != null) {
                        final url = widget.api.webdavFileUrl(m.filePath!);
                        imageIndex = imageItems.indexWhere(
                          (e) => e.url == url && e.messageId == m.id,
                        );
                      }

                      final author = m.actorDisplayName ?? m.actorId ?? 'User';
                      final bubble = Card(
                        color: isMe
                            ? Theme.of(context).colorScheme.primaryContainer
                            : null,
                        margin: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (!isMe)
                                    Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: CircleAvatar(
                                        radius: 10,
                                        child: Text(
                                          (author.isNotEmpty ? author[0] : '?')
                                              .toUpperCase(),
                                        ),
                                      ),
                                    ),
                                  Text(
                                    author,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              if (m.parentId != null)
                                ReplyMini(
                                  author: m.parentAuthor ?? 'Сообщение',
                                  snippet: m.parentIsFile
                                      ? (m.parentFileName ?? 'Вложение')
                                      : (m.parentText ?? ''),
                                  isFile: m.parentIsFile,
                                  onTap: () =>
                                      _scrollToMessageEnsureLoaded(m.parentId!),
                                ),
                              if (m.isFile)
                                FileBubble(
                                  api: widget.api,
                                  filePath: m.filePath!,
                                  mimeType:
                                      m.fileMime ??
                                      lookupMimeType(m.filePath!) ??
                                      'application/octet-stream',
                                  onOpenImage: imageIndex != null
                                      ? () => _openImageViewer(
                                          imageIndex!,
                                          imageItems,
                                        )
                                      : null,
                                )
                              else
                                SelectableText(
                                  m.message ?? '',
                                  enableInteractiveSelection: false,
                                ),
                              const SizedBox(height: 6),
                              Text(
                                dateFmt.format(
                                  DateTime.fromMillisecondsSinceEpoch(
                                    m.timestamp * 1000,
                                  ),
                                ),
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                              if (m.reactions.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Wrap(
                                    spacing: 6,
                                    runSpacing: 4,
                                    children: [
                                      for (final entry in m.reactions.entries)
                                        GestureDetector(
                                          onTap: () async {
                                            final emoji = entry.key;
                                            final mine = m.reactionsSelf
                                                .contains(emoji);
                                            try {
                                              if (mine) {
                                                await widget.api.deleteReaction(
                                                  widget.room.token,
                                                  m.id,
                                                  emoji,
                                                );
                                                setState(() {
                                                  m.reactionsSelf.remove(emoji);
                                                  final c =
                                                      m.reactions[emoji] ?? 1;
                                                  if (c <= 1) {
                                                    m.reactions.remove(emoji);
                                                  } else {
                                                    m.reactions[emoji] = c - 1;
                                                  }
                                                });
                                              } else {
                                                await widget.api.addReaction(
                                                  widget.room.token,
                                                  m.id,
                                                  emoji,
                                                );
                                                setState(() {
                                                  m.reactionsSelf.add(emoji);
                                                  m.reactions[emoji] =
                                                      (m.reactions[emoji] ??
                                                          0) +
                                                      1;
                                                });
                                              }
                                              Future.delayed(
                                                const Duration(seconds: 2),
                                                () {
                                                  if (mounted) _load();
                                                },
                                              );
                                            } catch (e) {
                                              if (!mounted) return;
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                SnackBar(
                                                  content: Text('Реакция: $e'),
                                                ),
                                              );
                                            }
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color:
                                                  m.reactionsSelf.contains(
                                                    entry.key,
                                                  )
                                                  ? Theme.of(context)
                                                        .colorScheme
                                                        .primary
                                                        .withOpacity(0.18)
                                                  : Theme.of(context)
                                                        .colorScheme
                                                        .surfaceVariant
                                                        .withOpacity(0.6),
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  entry.key,
                                                  style: const TextStyle(
                                                    fontSize: 16,
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                Text(
                                                  '${entry.value}',
                                                  style: Theme.of(
                                                    context,
                                                  ).textTheme.labelMedium,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );

                      final key = _msgKeys.putIfAbsent(m.id, () => GlobalKey());
                      return SizeReporter(
                        onHeight: (h) => _itemHeights[m.id] = h,
                        child: Align(
                          alignment: isMe
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: ConstrainedBox(
                            key: key,
                            constraints: const BoxConstraints(maxWidth: 480),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onLongPressStart: (_) =>
                                  HapticFeedback.mediumImpact(),
                              onLongPress: () => _openMessageMenu(m),
                              child: bubble,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              if (_replyTarget != null)
                SizeReporter(
                  onHeight: (h) => _replyBarHeight = h,
                  child: ReplyBar(
                    author:
                        _replyTarget!.actorDisplayName ??
                        _replyTarget!.actorId ??
                        'Сообщение',
                    snippet: _replyTarget!.isFile
                        ? p.basename(_replyTarget!.filePath ?? '')
                        : (_replyTarget!.message ?? ''),
                    isFile: _replyTarget!.isFile,
                    onTap: () {
                      final id = _replyTarget!.id;
                      _scrollToMessageEnsureLoaded(id);
                    },
                    onClose: () => setState(() => _replyTarget = null),
                  ),
                ),
              if (_isRecording)
                SizeReporter(
                  onHeight: (h) => _recordBarHeight = h,
                  child: _RecordingBanner(
                    level: _recAmp,
                    error: _recordError,
                    onCancel: _cancelRecord,
                    onStopAndSend: _toggleRecord,
                  ),
                ),
              SafeArea(
                child: SizeReporter(
                  onHeight: (h) => _inputBarHeight = h,
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.add),
                        onPressed: _openAttachSheet,
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: TextField(
                            controller: _input,
                            focusNode: _inputFocus,
                            decoration: const InputDecoration(
                              hintText: 'Сообщение...',
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                            onSubmitted: (_) => _sendText(),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.send),
                        onPressed: _sendText,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            right: 16,
            bottom:
                16.0 +
                MediaQuery.of(context).padding.bottom +
                _replyBarHeight +
                _recordBarHeight +
                _inputBarHeight,
            child: AnimatedScale(
              duration: const Duration(milliseconds: 150),
              scale: _showDownBtn ? 1 : 0.0,
              child: FloatingActionButton(
                heroTag: 'toBottom',
                mini: true,
                elevation: 3,
                onPressed: _scrollToBottom,
                child: const Icon(Icons.arrow_downward),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Доп. UI

class _RecordingBanner extends StatelessWidget {
  const _RecordingBanner({
    required this.level,
    required this.onCancel,
    required this.onStopAndSend,
    this.error,
  });

  final double level;
  final VoidCallback onCancel;
  final VoidCallback onStopAndSend;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final bg = Colors.red.withOpacity(0.08);
    final subtle = Theme.of(context).textTheme.bodyMedium;

    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: SafeArea(
        top: false,
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tight = constraints.maxWidth < 380;
            return Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 6,
              children: [
                const Icon(Icons.mic, color: Colors.red),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: tight
                        ? constraints.maxWidth * 0.35
                        : constraints.maxWidth * 0.45,
                  ),
                  child: Text(
                    error == null ? 'Идёт запись…' : error!,
                    style: subtle?.copyWith(
                      color: error == null ? null : Colors.red,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _RecordingEq(level: level),
                TextButton(onPressed: onCancel, child: const Text('Отменить')),
                FilledButton.icon(
                  onPressed: onStopAndSend,
                  icon: const Icon(Icons.stop),
                  label: Text(tight ? 'Стоп' : 'Стоп и отправить'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RecordingEq extends StatelessWidget {
  const _RecordingEq({required this.level});
  final double level;

  @override
  Widget build(BuildContext context) {
    final bars = <double>[0.9, 0.7, 1.0, 0.7, 0.9].map((w) {
      final h = (6 + 22 * (level * w)).clamp(6, 28).toDouble();
      return h;
    }).toList();

    return SizedBox(
      height: 28,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final h in bars)
            AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              width: 4,
              height: h,
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
  }
}

// Вспомогательная модель для галереи
class _ImageItem {
  _ImageItem({required this.url, required this.name, required this.messageId});
  final String url;
  final String name;
  final int messageId;
}
