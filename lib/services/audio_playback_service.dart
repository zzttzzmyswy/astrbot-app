// lib/services/audio_playback_service.dart
import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/message.dart';
import 'file_service.dart';
import 'play_queue.dart';
import '../providers/config_provider.dart';

/// 稳定标识一条消息,供气泡与播放服务对应(气泡会重建,key 不变)。
String messageKey(LocalMessage m) =>
    '${m.createdAt}|${m.localPath ?? m.attachmentId ?? ''}';

class PlaybackState {
  final String? currentKey;
  final PlayerState? playerState; // playing/paused/idle(null)
  final Duration position;
  final Duration duration;
  final bool loading;
  final List<String> queue;
  const PlaybackState({
    this.currentKey,
    this.playerState,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.loading = false,
    this.queue = const [],
  });

  bool isPlaying(String key) => currentKey == key && playerState == PlayerState.playing;
  bool isLoading(String key) => currentKey == key && loading;

  PlaybackState copyWith({
    String? currentKey,
    PlayerState? playerState,
    Duration? position,
    Duration? duration,
    bool? loading,
    List<String>? queue,
  }) => PlaybackState(
    currentKey: currentKey ?? this.currentKey,
    playerState: playerState ?? this.playerState,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    loading: loading ?? this.loading,
    queue: queue ?? this.queue,
  );
}

class AudioPlaybackNotifier extends StateNotifier<PlaybackState> {
  final AudioPlayer _player = AudioPlayer();
  final PlayQueue _queue = PlayQueue();
  final Map<String, LocalMessage> _msgByKey = {};
  final FileService _fileService;
  StreamSubscription? _posSub, _durSub, _stateSub, _completeSub;

  AudioPlaybackNotifier(this._fileService) : super(const PlaybackState()) {
    _posSub = _player.onPositionChanged.listen((p) {
      if (state.currentKey != null) state = state.copyWith(position: p);
    });
    _durSub = _player.onDurationChanged.listen((d) {
      if (state.currentKey != null) state = state.copyWith(duration: d);
    });
    // IMPORTANT: do NOT use copyWith for playerState because copyWith uses `??`
    // and would fail to clear completed→null. Instead rebuild PlaybackState
    // explicitly so null (idle) is representable.
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      if (s == PlayerState.completed) return; // handled by onPlayerComplete
      state = PlaybackState(
        currentKey: state.currentKey,
        playerState: s,
        position: state.position,
        duration: state.duration,
        loading: state.loading,
        queue: state.queue,
      );
    });
    _completeSub = _player.onPlayerComplete.listen((_) => _onComplete());
  }

  /// 手动切换/暂停/恢复。
  Future<void> toggle(LocalMessage m) async {
    final key = messageKey(m);
    _msgByKey[key] = m;
    if (state.currentKey == key) {
      if (state.playerState == PlayerState.playing) {
        await _player.pause();
      } else if (state.playerState == PlayerState.paused) {
        await _player.resume();
      } else {
        await _player.stop();
        await _playKey(key);
      }
      return;
    }
    // 切到别条:停旧(保留待播队列)
    await _player.stop();
    _queue.replaceCurrent(key);
    await _playKey(key);
  }

  /// 自动播放入队(bot 新语音)。
  Future<void> enqueue(LocalMessage m) async {
    final key = messageKey(m);
    _msgByKey[key] = m;
    final next = _queue.enqueue(key);
    state = state.copyWith(queue: _queue.queue);
    if (next != null) await _playKey(next);
  }

  Future<void> stop() async {
    await _player.stop();
    _queue.clear();
    _msgByKey.clear();
    state = const PlaybackState();
  }

  Future<void> seek(Duration pos) async {
    await _player.seek(pos);
    state = state.copyWith(position: pos);
  }

  Future<void> _playKey(String key) async {
    final m = _msgByKey[key];
    if (m == null) return;
    String? path = m.localPath;
    state = state.copyWith(currentKey: key, loading: false, position: Duration.zero, duration: Duration.zero);
    if (path == null || path.isEmpty) {
      final aid = m.attachmentId ?? '';
      if (aid.isEmpty) {
        _failCurrent();
        return;
      }
      state = state.copyWith(loading: true);
      try {
        final file = await _fileService.downloadAttachment(aid);
        path = file?.path;
      } catch (_) {
        path = null;
      }
      if (path == null || path.isEmpty) {
        state = state.copyWith(loading: false);
        _failCurrent();
        return;
      }
      state = state.copyWith(loading: false);
    }
    try {
      await _player.play(DeviceFileSource(path));
    } catch (_) {
      _failCurrent();
    }
  }

  /// 下载/播放失败:跳过当前,接下一条(避免一条坏消息卡死队列)。
  void _failCurrent() {
    _onComplete();
  }

  Future<void> _onComplete() async {
    _msgByKey.remove(_queue.current);
    final next = _queue.markComplete();
    state = state.copyWith(currentKey: next, queue: _queue.queue,
        position: Duration.zero, duration: Duration.zero);
    if (next != null) await _playKey(next);
  }

  @override
  void dispose() {
    _posSub?.cancel(); _durSub?.cancel(); _stateSub?.cancel(); _completeSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}

final audioPlaybackProvider =
    StateNotifierProvider<AudioPlaybackNotifier, PlaybackState>((ref) {
  final config = ref.read(configServiceProvider);
  return AudioPlaybackNotifier(
    FileService(serverUrl: config.serverUrl, apiKey: config.apiKey),
  );
});
