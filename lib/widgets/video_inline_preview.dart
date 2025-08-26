import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/playback_hub.dart';

class VideoInlinePreview extends StatefulWidget {
  const VideoInlinePreview({
    super.key,
    required this.url,
    required this.headers,
    required this.onOpenFull,
  });
  final String url;
  final Map<String, String> headers;
  final VoidCallback onOpenFull;

  @override
  State<VideoInlinePreview> createState() => _VideoInlinePreviewState();
}

class _VideoInlinePreviewState extends State<VideoInlinePreview> {
  VideoPlayerController? _ctrl;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _ctrl =
        VideoPlayerController.networkUrl(
            Uri.parse(widget.url),
            httpHeaders: widget.headers,
          )
          ..initialize().then((_) {
            if (!mounted) return;
            setState(() => _ready = true);
          });
    _ctrl?.setVolume(0);
    _ctrl?.pause();
    if (_ctrl != null) PlaybackHub.registerVideo(_ctrl!);
  }

  @override
  void dispose() {
    if (_ctrl != null) PlaybackHub.unregisterVideo(_ctrl!);
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    final double safeAR = ((ctrl?.value.aspectRatio ?? (16 / 9)).clamp(
      0.5,
      3.0,
    )).toDouble();

    return GestureDetector(
      onTap: widget.onOpenFull,
      child: AspectRatio(
        aspectRatio: safeAR,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_ready && ctrl != null)
              VideoPlayer(ctrl)
            else
              Container(color: Colors.black12),
            const Align(
              alignment: Alignment.center,
              child: Icon(Icons.play_circle, size: 48, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}
