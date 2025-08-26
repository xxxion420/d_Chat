import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../api/talk_api.dart';
import '../constants.dart';

class NcAvatar {
  static Widget user({
    required NextcloudTalkApi api,
    required String userId,
    String? displayName,
    double radius = 20,
  }) {
    final safeId = Uri.encodeComponent(userId);
    final url = '${kNcBase}/index.php/avatar/$safeId/${(radius * 2).round()}';
    return _NcAvatar(
      url: url,
      headers: api.authHeaders,
      fallbackText: _initial(displayName ?? userId),
      radius: radius,
    );
  }

  static Widget conversation({
    required NextcloudTalkApi api,
    required String token,
    String? displayName,
    double radius = 20,
  }) {
    return _NcRoomAvatar(
      api: api,
      token: token,
      radius: radius,
      fallbackText: _initial(displayName ?? token),
    );
  }

  static String _initial(String s) {
    final t = s.trim();
    if (t.isEmpty) return '?';
    final rune = t.runes.first;
    return String.fromCharCode(rune).toUpperCase();
  }
}

class _NcRoomAvatar extends StatefulWidget {
  const _NcRoomAvatar({
    required this.api,
    required this.token,
    required this.radius,
    required this.fallbackText,
  });

  final NextcloudTalkApi api;
  final String token;
  final double radius;
  final String fallbackText;

  @override
  State<_NcRoomAvatar> createState() => _NcRoomAvatarState();
}

class _NcRoomAvatarState extends State<_NcRoomAvatar> {
  static final Map<String, Uint8List> _cache = {};
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cacheKey = 'room:${widget.token}:${(widget.radius * 2).round()}';
    if (_cache.containsKey(cacheKey)) {
      setState(() => _bytes = _cache[cacheKey]);
      return;
    }
    try {
      final meta = await http.get(
        Uri.parse(
          '${kNcBase}/ocs/v2.php/apps/spreed/api/v4/room/${widget.token}/avatar?format=json',
        ),
        headers: {
          ...widget.api.authHeaders,
          'OCS-APIRequest': 'true',
          'Accept': 'application/json',
        },
      );
      if (meta.statusCode == 200) {
        final j = jsonDecode(meta.body);
        final rawUrl = (j['ocs']?['data']?['url'] ?? '').toString();
        if (rawUrl.isNotEmpty) {
          final fullUrl = rawUrl.startsWith('http')
              ? rawUrl
              : (rawUrl.startsWith('/')
                    ? '$kNcBase$rawUrl'
                    : '$kNcBase/$rawUrl');
          final img = await http.get(
            Uri.parse(fullUrl),
            headers: widget.api.authHeaders,
          );
          if (img.statusCode == 200 && mounted) {
            _cache[cacheKey] = img.bodyBytes;
            setState(() => _bytes = img.bodyBytes);
            return;
          }
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return CircleAvatar(
        radius: widget.radius,
        backgroundImage: MemoryImage(_bytes!),
      );
    }
    return CircleAvatar(
      radius: widget.radius,
      child: Text(widget.fallbackText),
    );
  }
}

class _NcAvatar extends StatefulWidget {
  const _NcAvatar({
    required this.url,
    required this.headers,
    required this.fallbackText,
    required this.radius,
  });

  final String url;
  final Map<String, String> headers;
  final String fallbackText;
  final double radius;

  @override
  State<_NcAvatar> createState() => _NcAvatarState();
}

class _NcAvatarState extends State<_NcAvatar> {
  static final Map<String, Uint8List> _cache = {};
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final key = '${widget.url}@${(widget.radius * 2).round()}';
    if (_cache.containsKey(key)) {
      setState(() => _bytes = _cache[key]);
      return;
    }
    try {
      final r = await http.get(Uri.parse(widget.url), headers: widget.headers);
      if (!mounted) return;
      if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) {
        _cache[key] = r.bodyBytes;
        setState(() => _bytes = r.bodyBytes);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return CircleAvatar(
        radius: widget.radius,
        backgroundImage: MemoryImage(_bytes!),
      );
    }
    return CircleAvatar(
      radius: widget.radius,
      child: Text(widget.fallbackText),
    );
  }
}

/// Для списков комнат — подменяет аватар на peer, если это 1:1
class RoomAvatar extends StatefulWidget {
  const RoomAvatar({
    super.key,
    required this.api,
    required this.room,
    this.radius = 20,
  });
  final NextcloudTalkApi api;
  final NcRoom room;
  final double radius;

  @override
  State<RoomAvatar> createState() => _RoomAvatarState();
}

class _RoomAvatarState extends State<RoomAvatar> {
  static final Map<String, String?> _peerCache = {}; // token -> other userId
  String? _peerId;
  String? _peerName;

  @override
  void initState() {
    super.initState();
    _resolvePeer();
  }

  Future<void> _resolvePeer() async {
    final cached = _peerCache[widget.room.token];
    if (cached != null) {
      _peerId = cached;
      setState(() {});
      return;
    }

    try {
      final parts = await widget.api.listParticipants(
        widget.room.token,
        includeStatus: false,
      );
      final me = widget.api.username;

      String norm(String s) => s.toLowerCase();
      final candidates = parts.where((p) {
        final t = norm(p.actorType);
        final isUser = t == 'user' || t == 'users' || t == 'federated_users';
        return isUser && (p.actorId ?? '').isNotEmpty;
      }).toList();

      final other = candidates.firstWhere(
        (p) => (p.actorId ?? '') != me,
        orElse: () =>
            NcParticipant(actorType: 'user', actorId: null, displayName: null),
      );

      if (!mounted) return;
      if (other.actorId != null) {
        _peerId = other.actorId;
        _peerName = other.displayName ?? other.actorId;
        _peerCache[widget.room.token] = _peerId;
        setState(() {});
        return;
      }
    } catch (_) {}

    // Fallback по сообщениям
    try {
      // Мягкий импорт модели для сборки — берём последние по default API
      final page = await widget.api.fetchMessagesPaged(
        widget.room.token,
        lookIntoFuture: 0,
        lastKnownId: null,
        limit: 30,
        setReadMarker: 0,
        markNotificationsAsRead: 0,
      );
      final me = widget.api.username;
      final msgs = page.messages.reversed.toList();
      final otherMsg = msgs.firstWhere(
        (m) => (m.actorId ?? '').isNotEmpty && (m.actorId ?? '') != me,
        orElse: () => NcMessage(id: -1, timestamp: 0),
      );
      if (otherMsg.id != -1) {
        _peerId = otherMsg.actorId;
        _peerName = otherMsg.actorDisplayName ?? otherMsg.actorId;
        _peerCache[widget.room.token] = _peerId;
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.room.displayName.isEmpty
        ? widget.room.token
        : widget.room.displayName;

    if (_peerId != null && _peerId!.isNotEmpty) {
      return NcAvatar.user(
        api: widget.api,
        userId: _peerId!,
        displayName: _peerName ?? name,
        radius: widget.radius,
      );
    }

    return NcAvatar.conversation(
      api: widget.api,
      token: widget.room.token,
      displayName: name,
      radius: widget.radius,
    );
  }
}
