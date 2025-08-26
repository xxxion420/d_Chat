import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/playback_hub.dart';

class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({
    super.key,
    required this.url,
    required this.headers,
    required this.title,
  });
  final String url;
  final Map<String, String> headers;
  final String title;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? _ctrl;
  bool _ready = false;

  bool _uiVisible = true;
  Timer? _hideTimer;

  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;

  late final AnimationController _dismissCtrl;
  double _dragOffsetX = 0.0;
  double _viewportWidth = 1.0;

  final TransformationController _tc = TransformationController();
  bool _isPinching = false;

  void _restartHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _uiVisible = false);
    });
  }

  @override
  void initState() {
    super.initState();
    _dismissCtrl =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 220),
        )..addListener(() {
          setState(() {
            _dragOffsetX = _viewportWidth * _dismissCtrl.value;
          });
        });

    _ctrl =
        VideoPlayerController.networkUrl(
            Uri.parse(widget.url),
            httpHeaders: widget.headers,
          )
          ..initialize().then((_) {
            if (!mounted) return;
            _dur = _ctrl!.value.duration;
            setState(() => _ready = true);
            _ctrl!.play();
            _restartHideTimer();
          });

    _ctrl?.addListener(() {
      if (!mounted || _ctrl == null) return;
      final v = _ctrl!.value;
      if (_dur != v.duration || _pos != v.position) {
        setState(() {
          _dur = v.duration;
          _pos = v.position;
        });
      }
    });
    if (_ctrl != null) PlaybackHub.registerVideo(_ctrl!);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    if (_ctrl != null) PlaybackHub.unregisterVideo(_ctrl!);
    _ctrl?.dispose();
    _dismissCtrl.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '${d.inMinutes.remainder(60)}:$s';
  }

  void _seekRelative(int seconds) {
    if (_ctrl == null) return;
    final target = _pos + Duration(seconds: seconds);
    Duration clamped;
    if (target < Duration.zero) {
      clamped = Duration.zero;
    } else if (_dur != Duration.zero && target > _dur) {
      clamped = _dur;
    } else {
      clamped = target;
    }
    _ctrl!.seekTo(clamped);
  }

  double _currentScale() => _tc.value.storage[0];

  void _onInteractionUpdate(ScaleUpdateDetails _) {
    setState(() {});
  }

  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    if (_isPinching || _currentScale() > 1.01) return;
    setState(
      () => _dragOffsetX = (_dragOffsetX + d.delta.dx).clamp(
        0.0,
        double.infinity,
      ),
    );
  }

  void _onHorizontalDragEnd(DragEndDetails d) {
    if (_isPinching || _currentScale() > 1.01) {
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
    final ctrl = _ctrl;
    final progress = _dur.inMilliseconds == 0
        ? 0.0
        : _pos.inMilliseconds / _dur.inMilliseconds;
    _viewportWidth = MediaQuery.of(context).size.width;
    final bgAlpha =
        (1.0 - (_dragOffsetX / _viewportWidth).clamp(0.0, 1.0)) * 0.6;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _uiVisible = !_uiVisible);
          if (_uiVisible) _restartHideTimer();
        },
        onDoubleTapDown: (details) {
          final w = MediaQuery.of(context).size.width;
          if (details.localPosition.dx < w / 2) {
            _seekRelative(-10);
          } else {
            _seekRelative(10);
          }
          if (_uiVisible) _restartHideTimer();
        },
        onScaleStart: (_) => setState(() => _isPinching = true),
        onScaleEnd: (_) => setState(() => _isPinching = false),
        onHorizontalDragUpdate: _onHorizontalDragUpdate,
        onHorizontalDragEnd: _onHorizontalDragEnd,
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(color: Colors.black.withOpacity(bgAlpha)),
            ),
            Transform.translate(
              offset: Offset(_dragOffsetX, 0),
              child: Center(
                child: _ready && ctrl != null
                    ? InteractiveViewer(
                        transformationController: _tc,
                        minScale: 1.0,
                        maxScale: 5.0,
                        panEnabled: true,
                        scaleEnabled: true,
                        clipBehavior: Clip.none,
                        onInteractionUpdate: _onInteractionUpdate,
                        child: AspectRatio(
                          aspectRatio: ctrl.value.aspectRatio,
                          child: VideoPlayer(ctrl),
                        ),
                      )
                    : const CircularProgressIndicator(color: Colors.white70),
              ),
            ),
            AnimatedSlide(
              offset: _uiVisible ? Offset.zero : const Offset(0, -1),
              duration: const Duration(milliseconds: 200),
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
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Назад'),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedSlide(
              offset: _uiVisible ? Offset.zero : const Offset(0, 1),
              duration: const Duration(milliseconds: 200),
              child: SafeArea(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Text(
                              _fmt(_pos),
                              style: const TextStyle(
                                color: Colors.white,
                                fontFeatures: [ui.FontFeature.tabularFigures()],
                              ),
                            ),
                            const Spacer(),
                            Text(
                              _fmt(_dur),
                              style: const TextStyle(
                                color: Colors.white,
                                fontFeatures: [ui.FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 4,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 7,
                            ),
                          ),
                          child: Slider(
                            value: _dur.inMilliseconds == 0
                                ? 0
                                : _pos.inMilliseconds
                                      .clamp(0, _dur.inMilliseconds)
                                      .toDouble(),
                            min: 0,
                            max:
                                (_dur.inMilliseconds == 0
                                        ? 1
                                        : _dur.inMilliseconds)
                                    .toDouble(),
                            onChangeStart: (_) => _hideTimer?.cancel(),
                            onChanged: (v) => setState(
                              () => _pos = Duration(milliseconds: v.toInt()),
                            ),
                            onChangeEnd: (v) {
                              ctrl?.seekTo(Duration(milliseconds: v.toInt()));
                              _restartHideTimer();
                            },
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              iconSize: 36,
                              color: Colors.white,
                              icon: const Icon(Icons.replay_10),
                              onPressed: () => _seekRelative(-10),
                            ),
                            const SizedBox(width: 12),
                            FilledButton(
                              onPressed: ctrl == null
                                  ? null
                                  : () {
                                      if (ctrl.value.isPlaying) {
                                        ctrl.pause();
                                      } else {
                                        ctrl.play();
                                      }
                                      setState(() {});
                                      _restartHideTimer();
                                    },
                              child: Icon(
                                ctrl != null && ctrl.value.isPlaying
                                    ? Icons.pause
                                    : Icons.play_arrow,
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              iconSize: 36,
                              color: Colors.white,
                              icon: const Icon(Icons.forward_10),
                              onPressed: () => _seekRelative(10),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (!_uiVisible)
              SafeArea(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    height: 2,
                    child: LinearProgressIndicator(
                      value: _dur.inMilliseconds == 0
                          ? null
                          : progress.clamp(0.0, 1.0),
                      backgroundColor: Colors.white.withOpacity(0.15),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Colors.white.withOpacity(0.9),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
