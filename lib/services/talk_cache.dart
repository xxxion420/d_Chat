import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/talk_api.dart';
import '../services/image_disk_cache.dart';

class TalkCache {
  static const _maxKeep = 80;

  static Future<File> _file(String roomToken) async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'talk_tail_$roomToken.json'));
  }

  /// Старый метод (оставлен для совместимости)
  static Future<void> saveTail(String roomToken, List<NcMessage> all) async {
    try {
      final visible = all.where((m) => !m.isSystemLike).toList();
      final tail = visible.length <= _maxKeep
          ? visible
          : visible.sublist(visible.length - _maxKeep);
      final file = await _file(roomToken);
      final jsonList = tail.map((m) => m.toCacheJson()).toList();
      await file.writeAsString(jsonEncode(jsonList));
    } catch (_) {}
  }

  /// Новый метод: сохраняет хвост + подкачивает изображения в дисковый кэш
  static Future<void> saveTailWithMedia(
    NextcloudTalkApi api,
    String roomToken,
    List<NcMessage> all,
  ) async {
    await saveTail(roomToken, all);

    try {
      final visible = all.where((m) => !m.isSystemLike).toList();
      final tail = visible.length <= _maxKeep
          ? visible
          : visible.sublist(visible.length - _maxKeep);

      final urls = <String>{};
      for (final m in tail) {
        if (m.isFile &&
            (m.fileMime?.startsWith('image/') ?? false) &&
            m.filePath != null) {
          urls.add(api.webdavFileUrl(m.filePath!));
        }
      }
      if (urls.isEmpty) return;

      const batch = 4;
      final list = urls.toList();
      for (int i = 0; i < list.length; i += batch) {
        final slice = list.sublist(
          i,
          i + batch > list.length ? list.length : i + batch,
        );
        await Future.wait(
          slice.map((url) async {
            if (await ImageDiskCache.exists(url)) return;
            try {
              final r = await http.get(
                Uri.parse(url),
                headers: api.authHeaders,
              );
              if (r.statusCode == 200 && r.bodyBytes.isNotEmpty) {
                await ImageDiskCache.put(url, r.bodyBytes);
              }
            } catch (_) {}
          }),
        );
      }
    } catch (_) {}
  }

  static Future<List<NcMessage>?> loadTail(String roomToken) async {
    try {
      final file = await _file(roomToken);
      if (!await file.exists()) return null;
      final s = await file.readAsString();
      final arr = (jsonDecode(s) as List).cast<Map<String, dynamic>>();
      return arr.map((j) => NcMessage.fromCacheJson(j)).toList();
    } catch (_) {
      return null;
    }
  }
}
