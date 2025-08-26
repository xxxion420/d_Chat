import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../services/playback_hub.dart';
import '../utils/math_utils.dart';

class AudioVoiceBubble extends StatefulWidget {
  const AudioVoiceBubble({super.key, required this.url, required this.headers});
  final String url;
  final Map<String, String> headers;

  @override
  State<AudioVoiceBubble> createState() => _AudioVoiceBubbleState();
}

class _AudioVoiceBubbleState extends State<AudioVoiceBubble> {
  late final AudioPlayer _player;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;

  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _ready = false;

  late final List<double> _wave;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    PlaybackHub.registerAudio(_player);
    _init();
    _posSub = _player.positionStream.listen((d) {
      if (!mounted) return;
      setState(() => _pos = d);
    });
    _stateSub = _player.playerStateStream.listen((_) {
      if (!mounted) return;
      setState(() {});
    });

    _wave = _makeWave(widget.url);
  }

  @override
  void dispose() {
    PlaybackHub.unregisterAudio(_player);
    _posSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  List<double> _makeWave(String seed) {
    final n = 64;
    final out = List<double>.filled(n, 0.0);
    int s = seed.hashCode ^ 0x9e3779b9;
    double rnd() {
      s ^= (s << 13);
      s ^= (s >> 17);
      s ^= (s << 5);
      return ((s & 0x7fffffff) / 0x7fffffff);
    }

    for (int i = 0; i < n; i++) {
      final f1 = rnd();
      final f2 = rnd();
      final f3 = rnd();
      double v = 0.55 * f1 + 0.3 * f2 + 0.15 * f3;
      v += 0.12 * MathUtils.sin(i * 0.6) + 0.08 * MathUtils.sin(i * 0.18 + 1.7);
      out[i] = v;
    }
    for (int k = 0; k < 2; k++) {
      for (int i = 1; i < n - 1; i++) {
        out[i] = (out[i - 1] + out[i] * 2 + out[i + 1]) / 4.0;
      }
    }
    double minV = out.reduce((a, b) => a < b ? a : b);
    double maxV = out.reduce((a, b) => a > b ? a : b);
    final range = (maxV - minV).abs() < 1e-6 ? 1.0 : (maxV - minV);
    return out
        .map((v) => ((v - minV) / range))
        .map((v) => (0.15 + 0.85 * v).clamp(0.15, 1.0).toDouble())
        .toList();
  }

  Future<void> _init() async {
    try {
      await _player.setUrl(widget.url, headers: widget.headers);
      if (!mounted) return;
      setState(() {
        _ready = true;
        _dur = _player.duration ?? Duration.zero;
      });
    } catch (_) {}
  }

  void _toggle() async {
    if (!_ready) return;
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
    if (!mounted) return;
    setState(() {});
  }

  void _seekTo(double frac) {
    if (_dur.inMilliseconds == 0) return;
    final ms = (frac * _dur.inMilliseconds)
        .clamp(0, _dur.inMilliseconds)
        .toInt();
    _player.seek(Duration(milliseconds: ms));
  }

  @override
  Widget build(BuildContext context) {
    final playing = _player.playing;
    final frac = _dur.inMilliseconds == 0
        ? 0.0
        : _pos.inMilliseconds / _dur.inMilliseconds;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withOpacity(0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: _ready ? _toggle : null,
            customBorder: const CircleBorder(),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                final box = d.localPosition.dx;
                final width = context.size?.width ?? 1;
                _seekTo(((box / width).clamp(0.0, 1.0)).toDouble());
              },
              child: CustomPaint(
                painter: _WavePainter(
                  _wave,
                  progress: frac,
                  color: Theme.of(context).colorScheme.primary,
                ),
                size: const Size(double.infinity, 36),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _format(_pos),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  String _format(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.values, {required this.progress, required this.color});
  final List<double> values;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paintBg = Paint()
      ..color = Colors.grey.withOpacity(0.35)
      ..style = PaintingStyle.fill;
    final paintFg = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final n = values.length;
    final barWidth = size.width / (n * 1.6);
    final gap = barWidth * 0.6;
    final baseline = size.height / 2;

    double x = 0;
    for (int i = 0; i < n; i++) {
      final h = values[i] * (size.height / 2);
      final rect = Rect.fromLTWH(x, baseline - h, barWidth, h * 2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        paintBg,
      );

      final filledTo = progress * size.width;
      if (x < filledTo) {
        final fillWidth = (filledTo - x).clamp(0, barWidth).toDouble();
        if (fillWidth > 0) {
          final r2 = Rect.fromLTWH(x, baseline - h, fillWidth, h * 2);
          canvas.drawRRect(
            RRect.fromRectAndRadius(r2, const Radius.circular(2)),
            paintFg,
          );
        }
      }

      x += barWidth + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.progress != progress ||
      oldDelegate.color != color;
}
