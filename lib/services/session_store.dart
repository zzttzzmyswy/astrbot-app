// lib/services/session_store.dart
//
// 会话注册表的纯逻辑(依赖 SessionStorage 抽象,便于单测用内存实现)。
// 职责:加载/持久化会话列表与当前会话 id;增删改;25 上限;首启种子迁移;
// 切换当前会话;删除当前会话时切到另一个。
//
// 设计:不在本类内碰 SharedPreferences,所有读写经 [SessionStorage],便于在
// flutter_test 环境用内存 fake 验证业务逻辑(注册表排序/上限/种子)。

import 'dart:convert';

import '../models/chat_session.dart';

/// 键值字符串存储抽象(生产用 SharedPreferences 包装,测试用内存实现)。
abstract class SessionStorage {
  Future<String?> readString(String key);
  Future<void> writeString(String key, String value);
}

/// 单个会话注册表的持久化根 JSON key。
const _kSessionsKey = 'chat_sessions_v1';
const _kCurrentIdKey = 'chat_sessions_current_v1';

/// 单个用户最多保留的会话数(产品约束)。
const int kMaxSessions = 25;

/// 新会话「尚未注册」时(服务端尚未回传 session_id)用的占位 currentId。
/// UI 展示「新会话」占位;首条消息后 session_id 事件到达时落为真实会话。
const String kPendingSessionId = '';

class SessionStore {
  final SessionStorage _storage;
  SessionStore(this._storage);

  List<ChatSession> _sessions = const [];
  String? _currentId; // 非 null 表示已加载;值可能为 kPendingSessionId
  bool _loaded = false;

  List<ChatSession> get sessions {
    _ensureLoaded();
    return List.unmodifiable(_sessions);
  }

  /// 当前会话 id;kPendingSessionId 表示「新会话占位」(服务端尚未回传)。
  String get currentId {
    _ensureLoaded();
    return _currentId ?? kPendingSessionId;
  }

  void _ensureLoaded() {
    if (!_loaded) {
      throw StateError('SessionStore 未加载,先调用 load()');
    }
  }

  Future<void> load() async {
    final raw = await _storage.readString(_kSessionsKey);
    List<ChatSession> list = const [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final arr = jsonDecode(raw);
        if (arr is List) {
          list = arr
              .map((e) => (e is Map) ? Map<String, dynamic>.from(e) : <String, dynamic>{})
              .map(ChatSession.fromJson)
              .toList();
        }
      } catch (_) {
        list = const []; // 损坏的 JSON 不致命:当作空注册表重新开始
      }
    }
    _sessions = _sortByLastUsed(list);
    _currentId = await _storage.readString(_kCurrentIdKey) ?? kPendingSessionId;
    _loaded = true;
  }

  /// 首启种子迁移:注册表为空且存在旧的单会话 session_id → 种一条会话,
  /// currentId 指向它。把现有单会话平滑升级为「会话 #1」。
  /// [legacySessionId] 来自 config_service 的旧 session_id;为空则不种(保持新会话占位)。
  Future<void> seedFromLegacy({
    required String? legacySessionId,
    String? legacyDisplayName,
  }) async {
    _ensureLoaded();
    if (_sessions.isNotEmpty) return; // 已有注册表,不覆盖
    final sid = legacySessionId;
    if (sid == null || sid.isEmpty) {
      _currentId = kPendingSessionId;
      await _persistCurrent();
      return;
    }
    final now = _nowMs();
    final seeded = ChatSession(
      id: sid,
      name: legacyDisplayName,
      createdAt: now,
      lastUsedAt: now,
    );
    _sessions = [seeded];
    _currentId = sid;
    await _persist();
  }

  /// 新建会话:切到「新会话占位」(currentId = kPendingSessionId)。
  /// 真实会话条目在服务端回传 session_id 后由 [registerServerSession] 落库。
  /// 返回 false 表示已达 25 上限,调用方应提示用户。
  Future<bool> beginNew() async {
    _ensureLoaded();
    // 占位不占名额(尚未注册),但若已达上限,不再开新的(避免无限累积)。
    if (_sessions.length >= kMaxSessions) return false;
    _currentId = kPendingSessionId;
    await _persistCurrent();
    return true;
  }

  /// 服务端回传 session_id(首条消息后)时落库为新会话。
  /// 若该 id 已存在(如重连复用),仅把 currentId 指过去并更新 lastUsedAt。
  /// [nowMs] 注入时间戳,便于测试。
  Future<ChatSession> registerServerSession(String sessionId, {required int nowMs}) async {
    _ensureLoaded();
    final existingIdx = _sessions.indexWhere((s) => s.id == sessionId);
    if (existingIdx >= 0) {
      final existing = _sessions[existingIdx];
      final updated = existing.copyWith(lastUsedAt: nowMs);
      final list = [..._sessions]..[existingIdx] = updated;
      _sessions = _sortByLastUsed(list);
      _currentId = sessionId;
      await _persist();
      return updated;
    }
    final created = ChatSession(
      id: sessionId,
      name: null, // 初始名由 UI 派生(服务端 id 前 8 位),用户可改名
      createdAt: nowMs,
      lastUsedAt: nowMs,
    );
    _sessions = [..._sessions, created];
    _currentId = sessionId;
    _sessions = _sortByLastUsed(_sessions);
    await _persist();
    return created;
  }

  /// 切换到指定会话。返回 false 表示该 id 不存在。
  Future<bool> select(String sessionId) async {
    _ensureLoaded();
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx < 0) return false;
    final now = _nowMs();
    final touched = _sessions[idx].copyWith(lastUsedAt: now);
    final list = [..._sessions]..[idx] = touched;
    _sessions = _sortByLastUsed(list);
    _currentId = sessionId;
    await _persist();
    return true;
  }

  /// 改名。返回 false 表示该 id 不存在。
  Future<bool> rename(String sessionId, String? name) async {
    _ensureLoaded();
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx < 0) return false;
    final trimmed = name?.trim();
    final list = [..._sessions]..[idx] = _sessions[idx].copyWith(
        name: (trimmed == null || trimmed.isEmpty) ? null : trimmed);
    _sessions = list;
    await _persist();
    return true;
  }

  /// 删除会话。若删的是当前会话,切到最近的另一个(或新会话占位)。
  /// 返回删除后应切换到的 currentId(供调用方据此重连/加载消息)。
  /// [deleteMessages] 回调由调用方提供,负责删该会话的本地消息。
  Future<String> delete(String sessionId, {required Future<void> Function(String) deleteMessages}) async {
    _ensureLoaded();
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx >= 0) {
      _sessions = [..._sessions]..removeAt(idx);
    }
    await deleteMessages(sessionId);
    String next;
    if (_currentId == sessionId) {
      next = _sessions.isEmpty ? kPendingSessionId : _sessions.first.id;
      _currentId = next;
      await _persist();
    } else {
      await _persist();
      next = _currentId ?? kPendingSessionId;
    }
    return next;
  }

  /// 触摸当前会话 lastUsedAt(发消息/收消息时),保持排序新鲜。
  Future<void> touchCurrent({required int nowMs}) async {
    _ensureLoaded();
    if (_currentId == null || _currentId == kPendingSessionId) return;
    final idx = _sessions.indexWhere((s) => s.id == _currentId);
    if (idx < 0) return;
    final list = [..._sessions]..[idx] = _sessions[idx].copyWith(lastUsedAt: nowMs);
    _sessions = _sortByLastUsed(list);
    await _persist();
  }

  Future<void> _persist() async {
    final arr = _sessions.map((s) => s.toJson()).toList();
    await _storage.writeString(_kSessionsKey, jsonEncode(arr));
    await _persistCurrent();
  }

  Future<void> _persistCurrent() async {
    await _storage.writeString(_kCurrentIdKey, _currentId ?? kPendingSessionId);
  }
}

// ---- 排序与时间 ----
List<ChatSession> _sortByLastUsed(List<ChatSession> list) {
  final copy = [...list]..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
  return copy;
}

int _nowMs() => DateTime.now().millisecondsSinceEpoch;
