import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../api/talk_api.dart';
import '../services/media_cache.dart';
import '../services/image_disk_cache.dart';
import '../widgets/video_inline_preview.dart';
import '../screens/video_player_screen.dart';
import 'audio_voice_bubble.dart';

class FileBubble extends StatefulWidget {
  const FileBubble({
    super.key,
    required this.api,
    required this.filePath,
    required this.mimeType,
    this.onOpenImage,
  });

  final NextcloudTalkApi api;
  final String filePath;
  final String mimeType;
  final VoidCallback? onOpenImage;

  @override
  State<FileBubble> createState() => _FileBubbleState();
}

class _FileBubbleState extends State<FileBubble> {
  Uint8List? _imageBytes;
  bool _loading = false;
  String? _error;
  late final String _webdavUrl;
  late final Map<String, String> _headers;

  @override
  void initState() {
    super.initState();
    _webdavUrl = widget.api.webdavFileUrl(widget.filePath);
    _headers = widget.api.authHeaders;
    if (widget.mimeType.startsWith('image/')) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cached = MediaCache.get(_webdavUrl);
      if (cached != null) {
        if (!mounted) return;
        setState(() => _imageBytes = cached);
      } else {
        final disk = await ImageDiskCache.get(_webdavUrl);
        if (disk != null) {
          MediaCache.set(_webdavUrl, disk);
          if (!mounted) return;
          setState(() => _imageBytes = disk);
        } else {
          final r = await http.get(Uri.parse(_webdavUrl), headers: _headers);
          if (!mounted) return;
          if (r.statusCode == 200) {
            MediaCache.set(_webdavUrl, r.bodyBytes);
            await ImageDiskCache.put(_webdavUrl, r.bodyBytes);
            setState(() => _imageBytes = r.bodyBytes);
          } else {
            setState(() => _error = 'HTTP ${r.statusCode}');
          }
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openVideo() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(
          url: _webdavUrl,
          headers: _headers,
          title: p.basename(widget.filePath),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isImg = widget.mimeType.startsWith('image/');
    final isAudio = widget.mimeType.startsWith('audio/');
    final isVideo = widget.mimeType.startsWith('video/');

    if (isImg) {
      if (_loading)
        return const SizedBox(
          height: 200,
          child: Center(child: CircularProgressIndicator()),
        );
      if (_error != null) return Text('Ошибка превью: $_error');
      if (_imageBytes == null) return const Text('Нет превью');
      return GestureDetector(
        onTap: widget.onOpenImage ?? () {},
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(_imageBytes!, fit: BoxFit.cover),
        ),
      );
    }

    if (isAudio) {
      // аудио-голос
      return AudioVoiceBubble(url: _webdavUrl, headers: _headers);
    }

    if (isVideo) {
      return VideoInlinePreview(
        url: _webdavUrl,
        headers: _headers,
        onOpenFull: _openVideo,
      );
    }

    final name = p.basename(widget.filePath);
    return ListTile(
      leading: const Icon(Icons.insert_drive_file_outlined),
      title: Text(name),
      subtitle: Text(widget.mimeType),
      trailing: IconButton(
        icon: const Icon(Icons.open_in_new),
        onPressed: () async {
          final uri = widget.api.basicAuthInUrl(_webdavUrl);
          final ok = await launchUrl(
            Uri.parse(uri),
            mode: LaunchMode.externalApplication,
          );
          if (!ok && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Не удалось открыть файл')),
            );
          }
        },
      ),
    );
  }
}

/// Локальный импорт, чтобы избежать циклических зависимостей
