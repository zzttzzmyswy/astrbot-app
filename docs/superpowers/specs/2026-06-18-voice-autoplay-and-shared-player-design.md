# 语音自动播放与共享播放器 — 设计

## 背景

AstrBot Android 客户端当前每个 `_VoiceBubble`(lib/screens/chat_screen.dart)自带一个 `AudioPlayer`,在 `State.dispose()` 中销毁。这导致两个问题:

1. **滚动出屏即停止播放** — `ListView` 回收气泡 → `_VoiceBubbleState.dispose()` → `_player.dispose()`,正在播放的语音被中断。
2. **多个气泡可同时播放** — 每个气泡独立持有播放器,互不知情,点开多个会叠加出声。

同时新增一个功能需求:

3. **自动播放开关** — 右上角设置按钮左侧加一个喇叭图标开关,默认关闭。打开后 bot 新发的语音自动播放。状态跨 app 重启持久化。bot 连续发多条语音时,排队顺序播放(当前播完自动接下一条)。

## 根因

问题 1、2 同源:播放器生命周期绑死在气泡 widget 上。解法是把播放器提到 widget 生命周期之外的单例服务 —— 播放与滚动解耦,单例天然互斥。

## 方案

Riverpod `StateNotifier` 持有单个 `AudioPlayer` + 待播队列(方案 A)。`_VoiceBubble` 退化为纯视图,订阅 service 状态。播放器随 provider 长存,与 widget 回收解耦;单 `AudioPlayer` 天然互斥;自动播放收口进同一个队列。

## 组件

### 1. `lib/services/audio_playback_service.dart`(新建)

```dart
class PlaybackState {
  final String? currentMessageKey;   // 当前播放消息的 key
  final PlayerState? playerState;    // playing/paused/idle(null)
  final Duration position;
  final Duration duration;
  final bool loading;                // 下载中
  final List<String> queue;          // 待播 messageKey 队列
  const PlaybackState({
    this.currentMessageKey,
    this.playerState,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.loading = false,
    this.queue = const [],
  });
}

class AudioPlaybackNotifier extends StateNotifier<PlaybackState> {
  final AudioPlayer _player = AudioPlayer();         // 单例,随 provider 长存
  final Map<String, LocalMessage> _msgByKey = {};    // key → 消息快照
  final FileService Function() _fileServiceFactory;  // 下载 bot 媒体
  // ...
}
```

- **messageKey** = `"${createdAt}|${localPath ?? attachmentId ?? ''}"`,用于在气泡与 service 间稳定标识一条消息。气泡 widget 会被重建,但 key 不变。
- **互斥**:无需显式锁。单 `AudioPlayer` 即天然互斥。
- **手动切换** `toggle(key, msg)`:
  - 当前正在播的就是本条且 `playing` → `pause`。
  - 当前是本条且 `paused` → `resume`。
  - 否则(idle / 别条)→ 若正在播别的 → `_player.stop()` 后播本条;播本条 = `play(key, msg)`。
- **`play(key, msg)`**:
  - 若 `localPath` 非空 → 直接 `_player.play(DeviceFileSource(localPath))`。
  - 若 `localPath` 空(典型为 bot 消息)且 `attachmentId` 非空 → `loading=true`,`FileService.downloadAttachment(attachmentId)` 拿本地路径,成功后 `_player.play(...)`,失败提示「语音下载失败」。
  - 记 `currentMessageKey = key`,把 msg 快照存入 `_msgByKey`。
- **自动播放入队** `enqueue(msg)`:
  - 计算 key。若 `currentMessageKey == null`(空闲)→ 立即 `play`。
  - 否则把 key 追加进 `state.queue`。
  - `_player.onPlayerComplete` → 清当前 key/进度,若队列非空 → 出队首条,用 `_msgByKey` 还原消息 `play`。
- **订阅** `initState` 里挂 `onPositionChanged`/`onDurationChanged`/`onPlayerStateChanged`/`onPlayerComplete`,更新 `state`。
- **dispose** `_player.dispose()`。

### 2. `_VoiceBubble` 改为纯视图(lib/screens/chat_screen.dart)

- 不再 `new AudioPlayer()`,不再 `dispose` 播放器。
- 用 `ref.listen(audioPlaybackProvider, ...)` 或直接 `ref.watch` 取 `PlaybackState`。
- 判定本气泡在播:`state.currentMessageKey == _myKey && state.playerState == playing`。
- 进度/时间取 `state.position`/`state.duration`;loading 态取 `state.loading && state.currentMessageKey == _myKey`。
- tap → `ref.read(audioPlaybackProvider).toggle(_myKey, widget.m)`。
- `_myKey` 由 `widget.m` 计算(同一算法)。
- 上传中(`status == uploading`)的展示分支保持不变(上传进度条),不进播放 service。

### 3. 喇叭开关 + 持久化

- `lib/services/config_service.dart`:加常量 `_kAutoPlayVoice`、`get autoPlayVoice => _prefs.getBool(_kAutoPlayVoice) ?? false`、`setAutoPlayVoice(bool)`。
- `ChatNotifier` 暴露 `autoPlayVoice` 状态(从 `ConfigService` 读初值)与 `setAutoPlayVoice(v)`(写 prefs + 更新 state),供 UI 读写。
- `lib/screens/chat_screen.dart` `_Bar.actions`:在 `more_vert` 设置按钮**左侧**插入 `IconButton`,图标 `Icons.volume_up_rounded`(开)/`Icons.volume_off_rounded`(关),开时 accent 高亮。tap 调 `setAutoPlayVoice(!current)`。
- 状态跨 app 重启保留(SharedPreferences)。

### 4. 自动播放触发

触发点:`ChatNotifier._handleEvent` 的 `attachment_saved` 分支(此时 bot 语音拿到真实 `attachmentId`,可下载)。

- 当 `mediaType` 归一为 audio 类别(`record`/`voice`/`audio`)、且 `autoPlayVoice == true` 时,把这条消息 `enqueue` 进 `AudioPlaybackNotifier`。
- 排队:空闲立即播;正在播入队,`onPlayerComplete` 自动出队接下一条(顺序播放)。
- `autoPlayVoice == false` 时不进队列,仅靠手动 tap。

边界:

- 多条语音几乎同时拿到 id → 按事件到达顺序入队 → 顺序播放。
- 自动播放进行中用户手动点别的气泡 → `toggle`「停旧播新」;**不清空**自动待播队列,只把当前换成手动那条。手动播完后 `onPlayerComplete` 仍会出队接下一条自动项。

## 错误处理

- 下载失败(attachment_id 无效 / 网络错):`play` 内 try/catch,`loading=false`,`currentMessageKey` 不设,弹 SnackBar「语音下载失败」。不入死循环。
- 队列里的消息若下载失败 → 跳过,继续出队下一条(避免一条坏消息卡死队列)。
- `_player.play` 抛错 → 同上处理,清当前 key。

## 测试

- `audio_playback_service` 的队列逻辑可用纯单测覆盖(注入假 `FileService`、fake player 或 mock):
  - 空闲 `enqueue` → 立即播。
  - 忙时 `enqueue` → 入队;`onPlayerComplete` → 出队接播,顺序正确。
  - `toggle` 在播放中暂停、暂停中恢复、切换到别条时停旧播新。
  - 队列项下载失败 → 跳过,继续下一条。
- `messageKey` 稳定性:同一消息重建 widget 后 key 不变。
- 手动验证(华为 logcat 加密,需屏幕诊断):
  - bot 发语音 → 自动播放(开关开)。
  - 播放中滚动让气泡出屏 → 播放继续。
  - 手动点 A 再点 B → 只有 B 在播。
  - 关 app 重开 → 喇叭开关状态保留。
  - bot 连发两条语音 → 第一条播完自动接第二条。

## 不在范围内(YAGNI)

- 不做全局播放控制条 / 通知栏控件。
- 不做自动播放的仅 Wi-Fi 限制。
- 不持久化播放队列(重启后队列清空,符合预期)。
- 不改动图片/文件/视频气泡。
