import 'dart:convert';
import 'dart:io';
import 'dart:async'; // <-- нужно для TimeoutException

import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import '../constants.dart';

class NextcloudTalkApi {
  NextcloudTalkApi(this.username, this.appPassword);
  final String username;
  final String appPassword;

  Map<String, String> get _headers => {
    'OCS-APIRequest': 'true',
    'Accept': 'application/json',
    'Authorization':
        'Basic ${base64Encode(utf8.encode('$username:$appPassword'))}',
  };

  Map<String, String> get authHeaders => {
    'Authorization':
        'Basic ${base64Encode(utf8.encode('$username:$appPassword'))}',
  };

  Uri _u(String path, [Map<String, String>? q]) =>
      Uri.parse(kNcBase + path).replace(queryParameters: q);

  String webdavFileUrl(String pathFromRoot) {
    final normalized = pathFromRoot.startsWith('/')
        ? pathFromRoot
        : '/$pathFromRoot';
    return '$kNcBase/remote.php/dav/files/$username$normalized';
  }

  String basicAuthInUrl(String url) {
    final uri = Uri.parse(url);
    final userInfo = '$username:$appPassword';
    return uri.replace(userInfo: userInfo).toString();
  }

  // ---- Rooms, participants, contacts ----

  Future<List<NcRoom>> listRooms({
    int limit = 100,
    bool includeStatus = false,
  }) async {
    final url = _u('/ocs/v2.php/apps/spreed/api/v4/room', {
      'format': 'json',
      'limit': '$limit',
      if (includeStatus) 'includeStatus': '1',
    });
    final r = await http.get(url, headers: _headers);
    if (r.statusCode != 200) {
      throw Exception('listRooms HTTP ${r.statusCode}: ${r.body}');
    }
    final data = jsonDecode(r.body);
    final list = (data['ocs']?['data'] as List?) ?? const [];
    return list
        .map((e) => NcRoom.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<List<NcParticipant>> listParticipants(
    String token, {
    bool includeStatus = false,
  }) async {
    final url = _u('/ocs/v2.php/apps/spreed/api/v4/room/$token', {
      'format': 'json',
      if (includeStatus) 'includeStatus': '1',
    });
    final r = await http.get(url, headers: _headers);
    if (r.statusCode != 200)
      throw Exception('participants HTTP ${r.statusCode}: ${r.body}');
    final data = jsonDecode(r.body);
    final arr = (data['ocs']?['data']?['participants'] as List?) ?? const [];
    return arr
        .map((e) => NcParticipant.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<NcRoom> createOrGetOneToOne(String userId) async {
    final url = _u('/ocs/v2.php/apps/spreed/api/v4/room', {'format': 'json'});
    final r = await http.post(
      url,
      headers: {
        ..._headers,
        'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
      },
      body: {'roomType': '1', 'invite': userId},
    );
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception('create 1:1 HTTP ${r.statusCode}: ${r.body}');
    }
    final data = jsonDecode(r.body);
    final j = (data['ocs']?['data'] as Map?)?.cast<String, dynamic>() ?? {};
    return NcRoom.fromJson(j);
  }

  // ---- Messaging (paged) ----

  Future<NcPage> fetchMessagesPaged(
    String token, {
    int lookIntoFuture = 1,
    int? lastKnownId,
    int limit = 100,
    int setReadMarker = 0,
    int markNotificationsAsRead = 0,
  }) async {
    final q = <String, String>{
      'format': 'json',
      'lookIntoFuture': '$lookIntoFuture',
      'limit': '$limit',
      'setReadMarker': '$setReadMarker',
      'markNotificationsAsRead': '$markNotificationsAsRead',
    };
    if (lastKnownId != null) q['lastKnownMessageId'] = '$lastKnownId';

    final url = _u('/ocs/v2.php/apps/spreed/api/v1/chat/$token', q);

    bool _isTransient(int code) =>
        code == 502 || code == 503 || code == 504 || code == 408;

    Future<http.Response?> _tryOnce() async {
      try {
        return await http
            .get(url, headers: _headers)
            .timeout(const Duration(seconds: 35));
      } on TimeoutException {
        return null; // transient
      }
    }

    http.Response? r = await _tryOnce();
    if (r == null || _isTransient(r.statusCode)) {
      await Future.delayed(const Duration(milliseconds: 400));
      r = await _tryOnce();
    }
    if (r == null) {
      return NcPage(messages: const [], lastGiven: lastKnownId);
    }
    if (r.statusCode == 304) {
      return NcPage(messages: const [], lastGiven: lastKnownId);
    }
    if (_isTransient(r.statusCode)) {
      return NcPage(messages: const [], lastGiven: lastKnownId);
    }
    if (r.statusCode != 200) {
      final code = r.statusCode;
      final ct = (r.headers['content-type'] ?? '').toLowerCase();
      final brief = ct.contains('application/json') ? r.body : 'HTTP $code';
      throw Exception('fetchMessages HTTP $code: $brief');
    }

    final data = jsonDecode(r.body);
    final dataNode = data['ocs']?['data'];

    List<dynamic> raw = const [];
    if (dataNode is Map) {
      final m = dataNode['message'];
      if (m is List)
        raw = m;
      else if (m is Map)
        raw = (m as Map).values.toList();
    } else if (dataNode is List) {
      raw = dataNode;
    }

    final out = <NcMessage>[];
    for (final e in raw) {
      if (e is Map)
        out.add(NcMessage.fromJson((e as Map).cast<String, dynamic>()));
    }
    final lastGivenHeader = r.headers['x-chat-last-given'];
    final lastGiven = int.tryParse(lastGivenHeader ?? '') ?? lastKnownId;

    return NcPage(messages: out, lastGiven: lastGiven);
  }

  Future<void> sendMessage(String token, String message, {int? replyTo}) async {
    final url = _u('/ocs/v2.php/apps/spreed/api/v1/chat/$token', {
      'format': 'json',
    });
    final body = <String, String>{'message': message};
    if (replyTo != null) body['replyTo'] = '$replyTo';
    final r = await http.post(
      url,
      headers: {
        ..._headers,
        'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
      },
      body: body,
    );
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception('sendMessage HTTP ${r.statusCode}: ${r.body}');
    }
  }

  Future<void> sendFileToChat(
    String token,
    File file, {
    String? overrideName,
    int? replyTo,
    String? caption,
    String? messageType,
  }) async {
    final name = overrideName ?? p.basename(file.path);
    final remotePath = '/Talk/${DateTime.now().millisecondsSinceEpoch}_$name';
    await _webdavUpload(file, remotePath);
    await shareExistingFileToChat(
      token,
      remotePath,
      caption: caption,
      replyTo: replyTo,
      messageType: messageType,
    );
  }

  Future<void> _webdavUpload(File file, String remotePath) async {
    final url = webdavFileUrl(remotePath);
    final bytes = await file.readAsBytes();
    final r = await http.put(Uri.parse(url), headers: authHeaders, body: bytes);
    if (r.statusCode != 201 && r.statusCode != 200 && r.statusCode != 204) {
      throw Exception('WebDAV upload HTTP ${r.statusCode}: ${r.body}');
    }
  }

  Future<void> shareExistingFileToChat(
    String token,
    String remotePath, {
    String? caption,
    int? replyTo,
    String? messageType,
  }) async {
    final url = _u('/ocs/v2.php/apps/files_sharing/api/v1/shares', {
      'format': 'json',
    });
    final talkMeta = <String, dynamic>{};
    if (caption != null && caption.isNotEmpty) talkMeta['caption'] = caption;
    if (replyTo != null) talkMeta['replyTo'] = replyTo;
    if (messageType != null) talkMeta['messageType'] = messageType;

    final body = <String, String>{
      'shareType': '10',
      'shareWith': token,
      'path': remotePath,
    };
    if (talkMeta.isNotEmpty) {
      body['talkMetaData'] = jsonEncode(talkMeta);
    }

    final r = await http.post(
      url,
      headers: {
        ..._headers,
        'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
      },
      body: body,
    );
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception('shareToChat HTTP ${r.statusCode}: ${r.body}');
    }
  }

  Future<void> addReaction(String token, int messageId, String emoji) async {
    final url = _u(
      '/ocs/v2.php/apps/spreed/api/v1/reaction/$token/$messageId',
      {'format': 'json'},
    );
    final r = await http.post(
      url,
      headers: {
        ..._headers,
        'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
      },
      body: {'reaction': emoji},
    );
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw Exception('addReaction HTTP ${r.statusCode}: ${r.body}');
    }
  }

  Future<void> deleteReaction(String token, int messageId, String emoji) async {
    final url = Uri.parse(
      kNcBase +
          '/ocs/v2.php/apps/spreed/api/v1/reaction/$token/$messageId?format=json',
    );
    final req = http.Request('DELETE', url)
      ..headers.addAll({
        ..._headers,
        'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
      })
      ..bodyFields = {'reaction': emoji};
    final resp = await http.Client().send(req);
    final code = resp.statusCode;
    if (code != 200 && code != 201) {
      final body = await resp.stream.bytesToString();
      throw Exception('deleteReaction HTTP $code: $body');
    }
  }

  Future<void> editMessage(String token, int messageId, String newText) async {
    final url = _u('/ocs/v2.php/apps/spreed/api/v1/chat/$token/$messageId', {
      'format': 'json',
    });
    final r = await http.put(
      url,
      headers: {
        ..._headers,
        'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
      },
      body: {'message': newText},
    );
    if (r.statusCode != 200 && r.statusCode != 202) {
      throw Exception('editMessage HTTP ${r.statusCode}: ${r.body}');
    }
  }

  Future<void> deleteMessage(String token, int messageId) async {
    final url = _u('/ocs/v2.php/apps/spreed/api/v1/chat/$token/$messageId', {
      'format': 'json',
    });
    final r = await http.delete(url, headers: _headers);
    if (r.statusCode != 200 && r.statusCode != 202) {
      throw Exception('deleteMessage HTTP ${r.statusCode}: ${r.body}');
    }
  }
}

class NcPage {
  NcPage({required this.messages, required this.lastGiven});
  final List<NcMessage> messages;
  final int? lastGiven;
}

class NcRoom {
  NcRoom({
    required this.token,
    required this.displayName,
    this.lastMessage,
    this.type,
    this.lastActivity,
  });

  final String token;
  final String displayName;
  final String? lastMessage;
  final int? type; // 1 = 1:1
  final int? lastActivity; // unix sec

  factory NcRoom.fromJson(Map<String, dynamic> j) {
    String _s(dynamic v) => v?.toString() ?? '';
    int _i(dynamic v) {
      if (v is int) return v;
      if (v is String) return int.tryParse(v) ?? 0;
      if (v is double) return v.toInt();
      return 0;
    }

    final token = _s(j['token'] ?? j['roomToken']);
    final name = _s(j['displayName'] ?? j['name']);
    String? last;
    try {
      last =
          (j['lastMessage']?['message']?['message'] ??
                  j['lastMessage']?['message'] ??
                  j['lastMessage'])
              ?.toString();
    } catch (_) {}

    int? lastAct;
    try {
      final la = j['lastActivity'] ?? j['lastActivityTime'];
      lastAct = la == null ? null : _i(la);
    } catch (_) {}

    final t = j['type'] ?? j['roomType'];

    return NcRoom(
      token: token,
      displayName: name,
      lastMessage: (last?.isEmpty ?? true) ? null : last,
      type: t == null ? null : _i(t),
      lastActivity: lastAct,
    );
  }
}

class NcParticipant {
  NcParticipant({required this.actorType, this.actorId, this.displayName});
  final String actorType; // 'users'
  final String? actorId;
  final String? displayName;

  factory NcParticipant.fromJson(Map<String, dynamic> j) {
    return NcParticipant(
      actorType: (j['actorType'] ?? j['type'] ?? '').toString(),
      actorId: (j['actorId'] ?? j['id'] ?? '').toString(),
      displayName: (j['displayName'] ?? j['name'] ?? '').toString(),
    );
  }
}

class NcMessage {
  NcMessage({
    required this.id,
    this.actorId,
    this.actorDisplayName,
    this.message,
    required this.timestamp,
    this.isFile = false,
    this.filePath,
    this.fileId,
    this.fileMime,
    this.messageType,
    this.isSystemLike = false,
    this.parentId,
    this.parentAuthor,
    this.parentText,
    this.parentIsFile = false,
    this.parentFileName,
    this.reactions = const {},
    this.reactionsSelf = const [],
  });

  final int id;
  final String? actorId;
  final String? actorDisplayName;
  final String? message;
  final int timestamp;

  final bool isFile;
  final String? filePath;
  final int? fileId;
  final String? fileMime;

  final String? messageType;
  final bool isSystemLike;

  // Reply info
  final int? parentId;
  final String? parentAuthor;
  final String? parentText;
  final bool parentIsFile;
  final String? parentFileName;

  final Map<String, int> reactions;
  final List<String> reactionsSelf;

  factory NcMessage.fromJson(Map<String, dynamic> j) {
    int _toInt(dynamic v) {
      if (v is int) return v;
      if (v is String) return int.tryParse(v) ?? 0;
      if (v is double) return v.toInt();
      return 0;
    }

    String? _toString(dynamic v) => v?.toString();

    bool isFile = false;
    String? filePath;
    int? fileId;
    String? fileMime;

    bool systemish = false;

    try {
      final params =
          j['parameters'] ?? j['messageParameters'] ?? j['message_parameter'];
      if (params is Map) {
        final file =
            params['file'] ??
            params['FILE'] ??
            params['attachment'] ??
            params['Attachment'];
        if (file is Map) {
          final rich = file['richObject'] ?? file['object'] ?? file;
          if (rich is Map) {
            filePath = _toString(
              rich['path'] ?? rich['link'] ?? rich['file'] ?? rich['name'],
            );
            fileId = _toInt(rich['id']);
            fileMime = _toString(
              rich['mimetype'] ??
                  rich['mime'] ??
                  lookupMimeType(filePath ?? ''),
            );
            isFile = filePath != null;
          }
        }
        if (params.containsKey('reaction') || params.containsKey('REACTION')) {
          systemish = true;
        }
      }
    } catch (_) {}

    final mtRaw = _toString(j['messageType'] ?? j['type'] ?? j['message_type']);
    final mt = mtRaw?.toLowerCase();
    if (mt != null) {
      if (mt.contains('system') ||
          mt.contains('reaction') ||
          mt.contains('activity') ||
          mt.contains('deleted') ||
          mt.contains('edit')) {
        systemish = true;
      }
    }
    final msgText = _toString(j['message'])?.toLowerCase() ?? '';
    if (msgText.contains('you edited') ||
        msgText.contains('вы изменили') ||
        msgText.contains('изменил') ||
        msgText.contains('удалил') ||
        msgText.contains('deleted') ||
        msgText.contains('reacted') ||
        msgText.contains('реакц')) {
      systemish = true;
    }

    // Parent info
    int? parentId;
    String? parentAuthor;
    String? parentText;
    bool parentIsFile = false;
    String? parentFileName;

    try {
      final parent = j['parent'];
      if (parent is Map) {
        parentId = _toInt(parent['id']);
        parentAuthor = _toString(
          parent['actorDisplayName'] ?? parent['actorId'],
        );
        parentText = _toString(parent['message']);
        final pParams = parent['parameters'] ?? parent['messageParameters'];
        if (pParams is Map) {
          final f = pParams['file'] ?? pParams['attachment'];
          if (f is Map) {
            final rich = f['richObject'] ?? f['object'] ?? f;
            if (rich is Map) {
              parentFileName = _toString(
                rich['name'] ?? rich['path'] ?? rich['file'],
              );
              parentIsFile = true;
            }
          }
        }
      }
    } catch (_) {}

    // Reactions
    Map<String, int> reactions = {};
    final rs = j['reactions'];
    if (rs is Map) {
      reactions = rs.map((k, v) => MapEntry(k.toString(), _toInt(v)));
    }
    List<String> reactionsSelf = [];
    final rself = j['reactionsSelf'];
    if (rself is List) {
      reactionsSelf = rself.map((e) => e.toString()).toList();
    }

    return NcMessage(
      id: _toInt(j['id']),
      actorId: _toString(j['actorId']),
      actorDisplayName: _toString(j['actorDisplayName']),
      message: _toString(j['message']),
      timestamp: _toInt(j['timestamp']),
      isFile: isFile,
      filePath: filePath,
      fileId: fileId,
      fileMime: fileMime,
      messageType: mtRaw,
      isSystemLike: systemish,
      parentId: parentId,
      parentAuthor: parentAuthor,
      parentText: parentText,
      parentIsFile: parentIsFile,
      parentFileName: parentFileName,
      reactions: reactions,
      reactionsSelf: reactionsSelf,
    );
  }

  Map<String, dynamic> toCacheJson() => {
    'id': id,
    'actorId': actorId,
    'actorDisplayName': actorDisplayName,
    'message': message,
    'timestamp': timestamp,
    'isFile': isFile,
    'filePath': filePath,
    'fileMime': fileMime,
    'messageType': messageType,
    'parentId': parentId,
    'parentAuthor': parentAuthor,
    'parentText': parentText,
    'parentIsFile': parentIsFile,
    'parentFileName': parentFileName,
    'reactions': reactions,
    'reactionsSelf': reactionsSelf,
  };

  factory NcMessage.fromCacheJson(Map<String, dynamic> j) => NcMessage(
    id: (j['id'] as num).toInt(),
    actorId: j['actorId'] as String?,
    actorDisplayName: j['actorDisplayName'] as String?,
    message: j['message'] as String?,
    timestamp: (j['timestamp'] as num).toInt(),
    isFile: (j['isFile'] as bool?) ?? false,
    filePath: j['filePath'] as String?,
    fileMime: j['fileMime'] as String?,
    messageType: j['messageType'] as String?,
    parentId: (j['parentId'] as num?)?.toInt(),
    parentAuthor: j['parentAuthor'] as String?,
    parentText: j['parentText'] as String?,
    parentIsFile: (j['parentIsFile'] as bool?) ?? false,
    parentFileName: j['parentFileName'] as String?,
    reactions:
        (j['reactions'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), (v as num).toInt()),
        ) ??
        const {},
    reactionsSelf:
        (j['reactionsSelf'] as List?)?.map((e) => e.toString()).toList() ??
        const [],
  );
}
