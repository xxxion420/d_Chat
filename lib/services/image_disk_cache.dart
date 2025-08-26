import 'dart:typed_data';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ImageDiskCache {
  static const _subdir = 'img_cache';
  static const _maxCount = 150;

  static Future<Directory> _dir() async {
    final base = await getTemporaryDirectory();
    final d = Directory(p.join(base.path, _subdir));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static String _hash(String s) {
    int hash = 0;
    for (final codeUnit in s.codeUnits) {
      hash += codeUnit;
      hash += (hash << 10);
      hash ^= (hash >> 6);
    }
    hash += (hash << 3);
    hash ^= (hash >> 11);
    hash += (hash << 15);
    final h = hash & 0xFFFFFFFF;
    return h.toRadixString(16).padLeft(8, '0');
  }

  static Future<File> _fileFor(String url) async {
    final d = await _dir();
    final ext = () {
      try {
        final u = Uri.parse(url);
        final name = p.basename(u.path);
        final e = p.extension(name);
        if (e.length >= 2 && e.length <= 5) return e;
      } catch (_) {}
      return '.bin';
    }();
    final name = '${_hash(url)}$ext';
    return File(p.join(d.path, name));
  }

  static Future<bool> exists(String url) async {
    final f = await _fileFor(url);
    return f.exists();
  }

  static Future<Uint8List?> get(String url) async {
    try {
      final f = await _fileFor(url);
      if (await f.exists()) {
        return await f.readAsBytes();
      }
    } catch (_) {}
    return null;
  }

  static Future<void> put(String url, Uint8List bytes) async {
    try {
      final f = await _fileFor(url);
      await f.writeAsBytes(bytes, flush: false);
      await _evictIfNeeded();
    } catch (_) {}
  }

  static Future<void> _evictIfNeeded() async {
    try {
      final d = await _dir();
      final files = await d
          .list()
          .where((e) => e is File)
          .cast<File>()
          .toList();

      if (files.length <= _maxCount) return;

      final stats = <File, DateTime>{};
      for (final f in files) {
        try {
          final s = await f.stat();
          stats[f] = s.modified;
        } catch (_) {}
      }
      final sorted = stats.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      final toDelete = sorted.take(sorted.length - _maxCount).map((e) => e.key);
      for (final f in toDelete) {
        try {
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
