// lib/providers/audio_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AudioState { idle, recording, playing }

class AudioNotifier extends StateNotifier<AudioState> {
  AudioNotifier() : super(AudioState.idle);

  void startRecording() => state = AudioState.recording;
  void stopRecording() => state = AudioState.idle;
  void startPlaying() => state = AudioState.playing;
  void stopPlaying() => state = AudioState.idle;
}

final audioProvider = StateNotifierProvider<AudioNotifier, AudioState>((ref) {
  return AudioNotifier();
});
