# 语音自动播放与共享播放器 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把语音播放器从气泡 widget 提到单例 Riverpod 服务,解决「滚动出屏即停」「多气泡同时播放」,并新增默认关闭、可持久化的喇叭自动播放开关(连发语音排队顺序播放)。

**Architecture:** 新增 `AudioPlaybackNotifier`(StateNotifier,持单 `AudioPlayer` + `PlayQueue`),`_VoiceBubble` 退化为纯视图订阅它;`ChatNotifier` 在 `attachment_saved` 拿到 bot 语音 `attachmentId` 且开关开时入队;`ConfigService` 持久化 `autoPlayVoice`;`_Bar` 加喇叭开关。

**Tech Stack:** Flutter 3.38、Riverpod 2.5、audioplayers 6.0、shared_preferences、sqflite、Dart。

---

## 文件结构

- 新建 `lib/services/play_queue.dart` — 纯队列逻辑(可单测,不依赖 AudioPlayer)。
- 新建 `lib/services/audio_playback_service.dart` — `AudioPlaybackNotifier` + `audioPlaybackProvider`,持单 `AudioPlayer`,接 `PlayQueue` + `FileService` 下载。
- 新建 `test/play_queue_test.dart` — 队列逻辑单测。
- 新建 `test/config_autoplay_test.dart` — 持久化开关单测。
- 改 `lib/services/config_service.dart` — 加 `autoPlayVoice` getter/setter。
- 改 `lib/providers/chat_provider.dart` — `ChatState`/`ChatNotifier` 加 `autoPlayVoice` 状态与 `setAutoPlayVoice`;`attachment_saved` 分支触发入队。
- 改 `lib/screens/chat_screen.dart` — `_VoiceBubble` 改纯视图;`_Bar` 加喇叭开关;`_ChatScreenState` 传递开关态与回调。

---

## Task 1: ConfigService 持久化 autoPlayVoice

**Files:**
- Modify: `lib/services/config_service.dart`
- Test: `test/config_autoplay_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// test/config_autoplay_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:astrbot_app/services/config_service.dart';

void main() {
  test('autoPlayVoice defaults to false and round-trips', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ConfigService();
    await c.init();
    expect(c.autoPlayVoice, isFalse); // 默认关闭
    await c.setAutoPlayVoice(true);
    expect(c.autoPlayVoice, isTrue);
    await c.setAutoPlayVoice(false);
    expect(c.autoPlayVoice, isFalse);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `/home/zzt/flutter/bin/flutter test test/config_autoplay_test.dart`
Expected: FAIL — `autoPlayVoice`/`setAutoPlayVoice` 未定义。

- [ ] **Step 3: 实现**

在 `lib/services/config_service.dart` 常量区(第 7-14 行附近)加:

```dart
  static const _kAutoPlayVoice = 'auto_play_voice';
```

在 getter 区(第 30 行 `connectionMode` getter 附近)加:

```dart
  bool get autoPlayVoice => _prefs.getBool(_kAutoPlayVoice) ?? false;
```

在 setter 区(第 32 行 `setConnectionMode` 附近)加:

```dart
  Future<void> setAutoPlayVoice(bool v) async => _prefs.setBool(_kAutoPlayVoice, v);
```

- [ ] **Step 4: 运行测试确认通过**

Run: `/home/zzt/flutter/bin/flutter test test/config_autoplay_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/services/config_service.dart test/config_autoplay_test.dart
git commit -m "feat: 持久化 autoPlayVoice 开关到 SharedPreferences"
```

---

## Task 2: PlayQueue 纯队列逻辑

**Files:**
- Create: `lib/services/play_queue.dart`
- Test: `test/play_queue_test.dart`

`PlayQueue` 维护「当前播放 key」与「待播 key 列表」,与 AudioPlayer 解耦,便于单测。`AudioPlaybackNotifier` 在 `onPlayerComplete` 时调 `markComplete()` 取下一条。

- [ ] **Step 1: 写失败测试**

```dart
// test/play_queue_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/services/play_queue.dart';

void main() {
  test('空闲 enqueue 立即成为当前', () {
    final q = PlayQueue();
    final next = q.enqueue('a');
    expect(next, 'a');
    expect(q.current, 'a');
    expect(q.queue, isEmpty);
  });

  test('忙时 enqueue 入队,markComplete 顺序出队', () {
    final q = PlayQueue();
    q.enqueue('a');          // 立即播放 a
    expect(q.enqueue('b'), isNull); // 正在播 a,b 入队,无即时返回
    expect(q.enqueue('c'), isNull);
    expect(q.queue, ['b', 'c']);
    expect(q.markComplete(), 'b');  // a 完 → 接 b
    expect(q.current, 'b');
    expect(q.markComplete(), 'c');  // b 完 → 接 c
    expect(q.markComplete(), isNull); // 队列空
    expect(q.current, isNull);
  });

  test('replaceCurrent 停旧播新但不清空待播队列', () {
    final q = PlayQueue();
    q.enqueue('a');
    q.enqueue('b');           // 待播 [b]
    expect(q.replaceCurrent('x'), 'x'); // 手动切 x
    expect(q.current, 'x');
    expect(q.queue, ['b']);   // 待播队列保留
  });

  test('clear 重置', () {
    final q = PlayQueue();
    q.enqueue('a'); q.enqueue('b');
    q.clear();
    expect(q.current, isNull);
    expect(q.queue, isEmpty);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `/home/zzt/flutter/bin/flutter test test/play_queue_test.dart`
Expected: FAIL — `PlayQueue` 不存在。

- [ ] **Step 3: 实现**

```dart
// lib/services/play_queue.dart

/// 语音播放队列的纯逻辑:维护「当前播放 key」与「待播 key 列表」。
/// 与 AudioPlayer 解耦,便于单测。enqueue 返回值:
/// - 空闲时返回该 key(调用方应立即播放),并设为 current;
/// - 忙时入队,返回 null。
/// markComplete 在一条播完时调用,返回下一条 key(或 null)。
/// replaceCurrent 用于手动切换:停旧播新,但保留待播队列。
class PlayQueue {
  String? _current;
  final List<String> _queue = [];

  String? get current => _current;
  List<String> get queue => List.unmodifiable(_queue);

  /// 入队。空闲(无 current)→ 立即成为 current 并返回该 key;
  /// 否则追加到队尾,返回 null。
  String? enqueue(String key) {
    if (_current == null) {
      _current = key;
      return key;
    }
    _queue.add(key);
    return null;
  }

  /// 当前播完。清 current,出队首条作为新的 current 并返回;
  /// 队列空则 current 置 null,返回 null。
  String? markComplete() {
    _current = null;
    if (_queue.isEmpty) return null;
    _current = _queue.removeAt(0);
    return _current;
  }

  /// 手动切换:把 current 换成新 key(停旧播新),待播队列保留。
  /// 返回新 key,调用方立即播放。
  String? replaceCurrent(String key) {
    _current = key;
    return key;
  }

  void clear() {
    _current = null;
    _queue.clear();
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `/home/zzt/flutter/bin/flutter test test/play_queue_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/services/play_queue.dart test/play_queue_test.dart
git commit -m "feat: 新增 PlayQueue 语音播放队列纯逻辑"
```

---

## Task 3: AudioPlaybackNotifier + provider

**Files:**
- Create: `lib/services/audio_playback_service.dart`

`AudioPlaybackNotifier` 持单个 `AudioPlayer`(随 provider 长存 → 滚动出屏不停、天然互斥),接 `PlayQueue`,负责下载 bot 媒体并播放,对外暴露 `PlaybackState`。

- [ ] **Step 1: 实现 messageKey 工具与 PlaybackState**

新建 `lib/services/audio_playback_service.dart`:

```dart
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
}
```

- [ ] **Step 2: 实现 AudioPlaybackNotifier**

在同一文件继续:

```dart
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
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      state = state.copyWith(playerState: s == PlayerState.completed ? null : s);
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
```

注:`state.copyWith` 需在 `PlaybackState` 上补一个 `copyWith`(见 Step 3)。

- [ ] **Step 3: 给 PlaybackState 加 copyWith**

在 `PlaybackState` 类内追加:

```dart
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
```

注意:`copyWith` 默认值合并对 `playerState==null`(idle)表达力不足——`_stateSub` 里用 `s == PlayerState.completed ? null : s` 显式传 null 时会被 `??` 回退成旧值。需把 `playerState` 改为哨兵模式:用 `Object? playerState = _unset` 同 `LocalMessage.uploadProgress`。为简化,改用独立方法重置:

把 `_stateSub` 改成:

```dart
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      // completed 由 onPlayerComplete 处理,这里不显示 completed
      if (s == PlayerState.completed) return;
      state = PlaybackState(
        currentKey: state.currentKey,
        playerState: s,
        position: state.position,
        duration: state.duration,
        loading: state.loading,
        queue: state.queue,
      );
    });
```

并删除 `copyWith` 中对 `playerState` 的 `??`(保持上面 copyWith 即可,因为不再用它写 null)。确认 `copyWith` 不再被用来写 `playerState: null`。

- [ ] **Step 4: 静态分析**

Run: `/home/zzt/flutter/bin/flutter analyze lib/services/audio_playback_service.dart lib/services/play_queue.dart`
Expected: 无 error。

- [ ] **Step 5: 提交**

```bash
git add lib/services/audio_playback_service.dart
git commit -m "feat: 新增 AudioPlaybackNotifier 单例播放器(滚动不停、互斥、排队)"
```

---

## Task 4: ChatNotifier 接入自动播放入队

**Files:**
- Modify: `lib/providers/chat_provider.dart`

`ChatState` 加 `autoPlayVoice`;`ChatNotifier` 初值取自 `ConfigService`,`setAutoPlayVoice` 写 prefs 并更新 state;`attachment_saved` 分支里 bot 语音(audio 类别)且开关开时调 `audioPlaybackProvider` 入队。

- [ ] **Step 1: ChatState 加 autoPlayVoice 字段**

`lib/providers/chat_provider.dart` 的 `ChatState`(第 84-117 行):

字段区加 `final bool autoPlayVoice;`,构造默认 `this.autoPlayVoice = false`,`copyWith` 参数加 `bool? autoPlayVoice` 与 `autoPlayVoice: autoPlayVoice ?? this.autoPlayVoice`。

- [ ] **Step 2: ChatNotifier 初值与 setter**

`ChatNotifier`(第 119 行起):

构造体改为读初值:

```dart
  ChatNotifier(this._config) : super(ChatState(autoPlayVoice: _config.autoPlayVoice));
```

注:initializer 里访问 `_config` 合法(参数已赋值)。若 Dart 不允许在 initializer 引用实例成员前的 `_config`,改用:

```dart
  ChatNotifier(this._config) : super(const ChatState());

  // 紧接其后:
  bool get autoPlayVoice => state.autoPlayVoice;
  Future<void> setAutoPlayVoice(bool v) async {
    await _config.setAutoPlayVoice(v);
    state = state.copyWith(autoPlayVoice: v);
  }
```

并在 `ChatState` 构造默认改为 `this.autoPlayVoice = false`。采用本方案(initializer 不读 `_config`,更稳)。

- [ ] **Step 3: 持有 playback 引用并接入 attachment_saved**

`ChatNotifier` 字段区(第 121 行 `CacheService` 附近)加:

```dart
  AudioPlaybackNotifier? _playback; // 由 UI 层注入,避免 provider 循环依赖
  void attachPlayback(AudioPlaybackNotifier p) => _playback = p;
```

顶部 import:

```dart
import '../services/audio_playback_service.dart';
```

`_handleEvent` 的 `attachment_saved` 分支(第 453-488 行),在 `state = state.copyWith(messages: msgs);` 之前、且 `id != null` 命中后,补自动播放触发:

```dart
            // 自动播放:bot 语音拿到 attachmentId 后入队(开关开时)
            if (_playback != null && _config.autoPlayVoice && _mediaCategory(mediaType) == 'audio') {
              final target = target >= 0 ? msgs[target] : created;
              _playback!.enqueue(target);
            }
```

注意 `created` 与 `msgs[target]` 在两个分支各自定义(见现有代码第 474-484 行);上面代码放在两分支之后、`state = state.copyWith(...)` 之前,`target`/`created` 在作用域内可见。

- [ ] **Step 4: 静态分析**

Run: `/home/zzt/flutter/bin/flutter analyze lib/providers/chat_provider.dart`
Expected: 无 error。

- [ ] **Step 5: 提交**

```bash
git add lib/providers/chat_provider.dart
git commit -m "feat: ChatNotifier 接入语音自动播放入队(autoPlayVoice 持久化)"
```

---

## Task 5: _VoiceBubble 改为纯视图

**Files:**
- Modify: `lib/screens/chat_screen.dart`(第 843-971 行 `_VoiceBubble`/`_VoiceBubbleState`)

去掉自带 `AudioPlayer`,改为订阅 `audioPlaybackProvider`,tap 调 `toggle`。下载/loading 全交给 service。

- [ ] **Step 1: 重写 _VoiceBubbleState**

顶部 import(第 8 行附近已有 `audioplayers`):

```dart
import '../services/audio_playback_service.dart';
```

替换 `_VoiceBubbleState`(第 849-970 行)为:

```dart
class _VoiceBubbleState extends ConsumerState<_VoiceBubble> {
  String get _key => messageKey(widget.m as LocalMessage);

  @override Widget build(BuildContext ctx) {
    final fg = widget.fg;
    final accent = const Color(0xFF5B4BD6);
    final m = widget.m as LocalMessage;
    final pb = ref.watch(audioPlaybackProvider);
    final player = ref.read(audioPlaybackProvider.notifier);

    // 上传中:走旧的上传进度行,不进播放 service
    if (m.status == MessageStatus.uploading) {
      final prog = m.uploadProgress ?? 0;
      return Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 18, height: 18, child: CircularProgressIndicator(
          value: prog > 0 ? prog : null, strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(accent))),
        const SizedBox(width: 8),
        Icon(Icons.cloud_upload_rounded, color: accent, size: 18),
        const SizedBox(width: 6),
        Text('上传中 ${(prog * 100).round()}%', style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w500)),
      ]);
    }

    final loading = pb.isLoading(_key);
    final playing = pb.isPlaying(_key);
    final paused = pb.currentKey == _key && pb.playerState == PlayerState.paused;
    final max = pb.duration.inMilliseconds.toDouble().clamp(1.0, double.infinity);
    final val = pb.position.inMilliseconds.toDouble().clamp(0.0, max);
    final active = pb.currentKey == _key; // 当前播放/暂停的就是本条

    String timeText(Duration d) {
      final s = d.inSeconds.abs();
      return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (loading)
        const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2))
      else GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => player.toggle(m),
        child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: active ? accent : fg, size: 26)),
      const SizedBox(width: 6),
      Icon(Icons.mic_rounded, color: active ? accent : fg, size: 18),
      const SizedBox(width: 2),
      SizedBox(
        width: 90,
        child: SliderTheme(
          data: SliderThemeData(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            activeTrackColor: accent,
            inactiveTrackColor: fg.withOpacity(0.3),
            thumbColor: accent,
          ),
          child: Slider(
            value: val,
            min: 0,
            max: max,
            onChanged: active ? (v) => player.seek(Duration(milliseconds: v.round())) : null,
            onChangeEnd: active ? (v) => player.seek(Duration(milliseconds: v.round())) : null,
          ),
        ),
      ),
      const SizedBox(width: 4),
      SizedBox(width: 38,
        child: Text(timeText(pb.position), style: TextStyle(color: fg.withOpacity(0.8), fontSize: 11))),
      if (active) ...[
        const SizedBox(width: 2),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => player.stop(),
          child: Icon(Icons.stop_rounded, color: fg.withOpacity(0.8), size: 20)),
      ],
    ]);
  }
}
```

删除 `_VoiceBubbleState` 里原有的 `AudioPlayer _player`、`_state`、`_pos`、`_dur`、`_loading`、`initState`、`dispose`、`_toggle`、`_play`、`_stop`、`_timeText`。

- [ ] **Step 2: _ChatScreenState 注入 playback 给 ChatNotifier**

在 `_ChatScreenState` 的 `initState`(或 `_initSync`)中,provider 就绪后:

```dart
    ref.read(chatProvider.notifier).attachPlayback(ref.read(audioPlaybackProvider.notifier));
```

放在已有 `ref.read(chatProvider...)` 调用附近(参考现有 `_initSync` 结构)。import 已在第 1 步加。

- [ ] **Step 3: 静态分析**

Run: `/home/zzt/flutter/bin/flutter analyze lib/screens/chat_screen.dart`
Expected: 无 error(可能有无用 import 提示,清理)。

- [ ] **Step 4: 提交**

```bash
git add lib/screens/chat_screen.dart
git commit -m "refactor: _VoiceBubble 改为订阅共享播放器(滚动不停、互斥)"
```

---

## Task 6: _Bar 喇叭开关

**Files:**
- Modify: `lib/screens/chat_screen.dart`(`_Bar`,第 1184-1213 行;调用处第 163 行)

`_Bar` 加 `autoPlay` 与 `onToggleAutoPlay` 参数,在 `more_vert` 左侧插喇叭按钮。

- [ ] **Step 1: _Bar 增加参数与按钮**

`_Bar`(第 1184 行)改为:

```dart
class _Bar extends StatelessWidget implements PreferredSizeWidget {
  final bool conn, isDark, streaming, autoPlay;
  final String? error;
  final VoidCallback onToggleAutoPlay;
  const _Bar({
    required this.conn, required this.isDark, this.error,
    this.streaming = false, this.autoPlay = false, required this.onToggleAutoPlay,
  });
  @override Size get preferredSize => const Size.fromHeight(44);
  @override Widget build(BuildContext ctx) {
    final bg = isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF7F7F8);
    final txt = isDark ? Colors.white : Colors.black;
    final accent = const Color(0xFF007AFF);
    final statusText = conn ? '在线' : (error ?? '未连接');
    final statusColor = conn ? const Color(0xFF34C759) : const Color(0xFFFF6B6B);
    return AppBar(
      backgroundColor: bg, elevation: 0, titleSpacing: 16,
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('AstrBot', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: txt)),
        if (streaming)
          Row(mainAxisSize: MainAxisSize.min, children: [
            _TypingDots(color: accent),
            const SizedBox(width: 6),
            Text('正在输入...', style: TextStyle(fontSize: 11, color: accent)),
          ])
        else
          Text(statusText, style: TextStyle(fontSize: 11, color: statusColor)),
      ]),
      actions: [
        IconButton(
          icon: Icon(autoPlay ? Icons.volume_up_rounded : Icons.volume_off_rounded,
              size: 22, color: autoPlay ? accent : txt),
          tooltip: autoPlay ? '自动播放:开' : '自动播放:关',
          onPressed: onToggleAutoPlay,
        ),
        IconButton(icon: Icon(Icons.more_vert, size: 20, color: txt), onPressed: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => const SettingsScreen()))),
      ],
    );
  }
}
```

- [ ] **Step 2: 调用处传参**

第 163 行:

```dart
      appBar: _Bar(
        conn: conn, isDark: isDark, error: _state.errorMessage,
        streaming: _state.streamingText?.isNotEmpty == true,
        autoPlay: _state.autoPlayVoice,
        onToggleAutoPlay: () => ref.read(chatProvider.notifier).setAutoPlayVoice(!_state.autoPlayVoice),
      ),
```

- [ ] **Step 3: 静态分析**

Run: `/home/zzt/flutter/bin/flutter analyze lib/screens/chat_screen.dart`
Expected: 无 error。

- [ ] **Step 4: 提交**

```bash
git add lib/screens/chat_screen.dart
git commit -m "feat: 右上角加喇叭自动播放开关(默认关、持久化)"
```

---

## Task 7: 清理、构建、手动验证

- [ ] **Step 1: 全量 analyze**

Run: `/home/zzt/flutter/bin/flutter analyze`
Expected: 无 error。

- [ ] **Step 2: 全量测试**

Run: `/home/zzt/flutter/bin/flutter test`
Expected: 全部 PASS(含新 `play_queue_test.dart`、`config_autoplay_test.dart`)。

- [ ] **Step 3: 构建 arm64 release**

Run: `/home/zzt/flutter/bin/flutter build apk --release --target-platform android-arm64`
Expected: `✓ Built build/app/outputs/flutter-apk/app-release.apk`。

- [ ] **Step 4: 安装(用户屏幕确认)**

提示用户执行:`! adb install -r build/app/outputs/flutter-apk/app-release.apk`

- [ ] **Step 5: 手动验证清单(华为 logcat 加密,屏幕诊断)**

逐项确认:
1. 喇叭默认关闭(图标为 `volume_off`,灰色)。
2. 打开喇叭 → 图标变 `volume_up` + accent 色;关 app 重开 → 仍为开(持久化)。
3. 喇叭开 + 让 bot 发语音 → 自动播放。
4. 播放中向上滑动让该气泡滚出屏幕 → 播放继续(不停止)。
5. 手动点 A 播放,再点 B → A 停、只有 B 在播(互斥)。
6. bot 连发两条语音 → 第一条播完自动接第二条(排队顺序)。
7. 喇叭关 + bot 发语音 → 不自动播,手动点可播。
8. 上传中的自己语音仍显示上传进度条(未走播放 service)。

- [ ] **Step 6: 提交收尾(若有零散修改)**

```bash
git add -A
git commit -m "chore: 语音自动播放与共享播放器收尾"
```

---

## Self-Review 记录

- **Spec 覆盖**:问题1(滚动不停)= Task 3 单例 + Task 5 纯视图;问题2(互斥)= Task 3 单 player + toggle 停旧;功能开关持久化 = Task 1 + Task 6;排队顺序播放 = Task 2 + Task 3 + Task 4。全覆盖。
- **类型一致**:`messageKey(LocalMessage)`、`PlaybackState.isPlaying/isLoading`、`AudioPlaybackNotifier.toggle/enqueue/stop/seek`、`ChatNotifier.attachPlayback/setAutoPlayVoice` 跨任务签名一致。
- **无占位符**:每步含完整代码或确切命令。
