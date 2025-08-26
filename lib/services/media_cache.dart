import 'dart:typed_data';

/// Быстрый RAM-кэш для медиа
class MediaCache {
  static final _map = <String, Uint8List>{};
  static Uint8List? get(String k) => _map[k];
  static void set(String k, Uint8List v) {
    _map[k] = v;
  }
}
