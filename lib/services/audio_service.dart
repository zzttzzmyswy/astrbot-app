// lib/services/audio_service.dart
import 'dart:io';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

class AudioService {
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  String? _recordingPath;

  Future<bool> hasPermission() async {
    return await _recorder.hasPermission();
  }

  Future<void> startRecording() async {
    final dir = await getTemporaryDirectory();
    _recordingPath = '${dir.path}/draft_record.wav';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.wav),
      path: _recordingPath!,
    );
  }

  Future<File?> stopRecording() async {
    final path = await _recorder.stop();
    if (path != null && File(path).existsSync()) {
      return File(path);
    }
    return null;
  }

  /// 复用内部单一 recorder 暴露振幅流,避免调用方再 new 一个 AudioRecorder。
  Stream<Amplitude> amplitudeStream(Duration interval) {
    return _recorder.onAmplitudeChanged(interval);
  }

  Future<void> playFile(String path) async {
    await _player.play(DeviceFileSource(path));
  }

  Future<void> stopPlaying() async {
    await _player.stop();
  }

  Future<void> dispose() async {
    await _player.dispose();
    await _recorder.dispose();
  }
}
