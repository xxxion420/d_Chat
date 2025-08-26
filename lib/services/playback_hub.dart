import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

class PlaybackHub {
  static final _audioPlayers = <AudioPlayer>{};
  static final _videoCtrls = <VideoPlayerController>{};

  static void registerAudio(AudioPlayer p) => _audioPlayers.add(p);
  static void unregisterAudio(AudioPlayer p) => _audioPlayers.remove(p);

  static void registerVideo(VideoPlayerController c) => _videoCtrls.add(c);
  static void unregisterVideo(VideoPlayerController c) => _videoCtrls.remove(c);

  static Future<void> pauseAll() async {
    for (final p in _audioPlayers) {
      if (p.playing) {
        try {
          await p.pause();
        } catch (_) {}
      }
    }
    for (final v in _videoCtrls) {
      try {
        await v.pause();
      } catch (_) {}
    }
  }
}
