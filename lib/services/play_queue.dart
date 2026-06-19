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
