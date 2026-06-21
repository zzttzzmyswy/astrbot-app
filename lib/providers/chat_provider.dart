// lib/providers/chat_provider.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../models/chat_event.dart';
import '../models/message.dart';
import '../models/chat_session.dart';
import '../services/astrbot_sse_client.dart';
import '../services/astrbot_ws_client.dart';
import '../services/audio_playback_service.dart';
import '../services/cache_service.dart';
import '../services/config_service.dart';
import '../services/file_service.dart';
import '../services/prefs_storage.dart';
import '../services/session_store.dart';
import '../util/lifecycle_reconnect.dart';
import '../util/outbound.dart';
import 'config_provider.dart';

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  final config = ref.read(configServiceProvider);
  return ChatNotifier(config);
});

/// 把不同媒体类型归一到同一类别,用于 raw 事件占位与 attachment_saved 事件的匹配
/// (服务端 audio 可能用 record/voice/audio 等不同串,归一后才能正确合并,避免双气泡)。
String _mediaCategory(String t) {
  switch (t) {
    case 'voice':
    case 'audio':
    case 'record':
      return 'audio';
    case 'image':
    case 'photo':
      return 'image';
    case 'video':
      return 'video';
    default:
      return t; // 'file', 'document' 等
  }
}

class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> args;
  final int createdAt;

  const ToolCall({
    required this.id,
    required this.name,
    required this.args,
    required this.createdAt,
  });

  factory ToolCall.fromJson(Map<String, dynamic> json) {
    return ToolCall(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      args: (json['args'] as Map<String, dynamic>?) ?? {},
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class ToolResult {
  final String id;
  final String result;
  final int? ts;
  final int createdAt;

  const ToolResult({
    required this.id,
    required this.result,
    this.ts,
    required this.createdAt,
  });

  factory ToolResult.fromJson(Map<String, dynamic> json) {
    return ToolResult(
      id: json['id'] as String? ?? '',
      result: json['result']?.toString() ?? '',
      ts: json['ts'] as int?,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class ChatState {
  final List<LocalMessage> messages;
  final ConnState connectionState;
  final String? streamingText;
  final String? errorMessage;
  final List<ToolCall> toolCalls;
  final List<ToolResult> toolResults;
  final bool autoPlayVoice;
  final bool backgroundDisconnect;
  // 多会话:注册表 + 当前会话 id(kPendingSessionId 表示尚未由服务端分配的新会话)
  // + 当前会话展示名(用户自定义或由服务端 session_id 派生;占位为「新会话」)。
  final List<ChatSession> sessions;
  final String currentSessionId;
  final String currentSessionName;

  const ChatState({
    this.messages = const [],
    this.connectionState = ConnState.disconnected,
    this.streamingText,
    this.errorMessage,
    this.toolCalls = const [],
    this.toolResults = const [],
    this.autoPlayVoice = false,
    this.backgroundDisconnect = false,
    this.sessions = const [],
    this.currentSessionId = kPendingSessionId,
    this.currentSessionName = '新会话',
  });

  ChatState copyWith({
    List<LocalMessage>? messages,
    ConnState? connectionState,
    String? streamingText,
    String? errorMessage,
    List<ToolCall>? toolCalls,
    List<ToolResult>? toolResults,
    bool? autoPlayVoice,
    bool? backgroundDisconnect,
    List<ChatSession>? sessions,
    String? currentSessionId,
    String? currentSessionName,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        connectionState: connectionState ?? this.connectionState,
        streamingText: streamingText,
        errorMessage: errorMessage,
        toolCalls: toolCalls ?? this.toolCalls,
        toolResults: toolResults ?? this.toolResults,
        autoPlayVoice: autoPlayVoice ?? this.autoPlayVoice,
        backgroundDisconnect: backgroundDisconnect ?? this.backgroundDisconnect,
        sessions: sessions ?? this.sessions,
        currentSessionId: currentSessionId ?? this.currentSessionId,
        currentSessionName: currentSessionName ?? this.currentSessionName,
      );
}

class ChatNotifier extends StateNotifier<ChatState> with WidgetsBindingObserver {
  final ConfigService _config;
  final CacheService _cache = CacheService();
  final SessionStore _sessions;
  bool _sessionsLoaded = false;
  dynamic _client;
  StreamSubscription<ChatEvent>? _eventSub;
  bool _usingWs = true;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  final List<List<Map<String, dynamic>>> _pendingQueue = [];
  /// 首轮回合后延迟取标题的定时器(complete/end 触发;4s 后取,给服务端后台
  /// 标题生成 LLM 留时间)。有标题后不再调度。
  Timer? _titleRefreshTimer;
  int _historyOffset = 0;
  bool _hasMoreHistory = true;
  AudioPlaybackNotifier? _playback;
  /// SSE 在途跟踪:当前正在等服务端响应的「我发出」文本消息的 createdAt。
  /// 仅 SSE 模式用 —— SSE 发送是 fire-and-forget,真正的失败经 error 事件回传,
  /// 靠这个把失败关联回具体消息。收到该消息的首个流式事件/complete/end 即清空。
  int? _inflightTextCreatedAt;

  ChatNotifier(this._config)
      : _sessions = SessionStore(PrefsSessionStorage(_config.prefs)),
        super(ChatState(autoPlayVoice: _config.autoPlayVoice)) {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _onAppResumed();
  }

  /// 回前台处理:优先检测 WS「僵尸」连接(仍报告 connected,但进程被 OS 冻结期间
  /// 无入站帧,_lastReceivedAt 已超沉默阈值 —— 这类 socket 的 onDone/onError 不会
  /// 触发,既有 shouldReconnectOnResume 漏判)。给短暂宽限让冻结期间缓冲的入站帧
  /// 先排空刷新 _lastReceivedAt,避免误判一个仍在正常生成中的连接。
  void _onAppResumed() {
    Future.delayed(const Duration(milliseconds: 800), _probeResumeLiveness);
  }

  void _probeResumeLiveness() {
    final client = _client;
    if (_usingWs &&
        client is AstrBotWsClient &&
        state2IsConnected &&
        client.isStale) {
      // 僵尸连接:强制重连(复用既有 teardown+重连路径,会落盘孤儿流式文本并按
      // 既有退避重连,同 session_id 保留上下文)。
      client.forceReconnect();
      _markBackgroundDisconnect();
    } else if (shouldReconnectOnResume(
        current: AppLifecycleState.resumed, isConnected: state2IsConnected)) {
      connect();
    }
  }

  /// 标记「后台期间连接被掐」——供 UI 在荣耀/华为等机型上重弹白名单引导。
  void _markBackgroundDisconnect() {
    if (!state.backgroundDisconnect) {
      state = state.copyWith(backgroundDisconnect: true);
    }
  }

  /// UI 展示完白名单引导后清除该标志。
  void clearBackgroundDisconnect() {
    if (state.backgroundDisconnect) {
      state = state.copyWith(backgroundDisconnect: false);
    }
  }

  bool get state2IsConnected => state.connectionState == ConnState.connected;

  /// 由 UI 注入播放器实例,用于自动播放入队。
  void attachPlayback(AudioPlaybackNotifier p) => _playback = p;

  bool get autoPlayVoice => state.autoPlayVoice;

  /// 切换自动播放开关:写 prefs + 更新 state(驱动 UI 图标渲染)。
  Future<void> setAutoPlayVoice(bool v) async {
    await _config.setAutoPlayVoice(v);
    state = state.copyWith(autoPlayVoice: v);
  }

  String? _resolvedConfigId;

  /// 首启加载会话注册表:若为空且存在旧的单会话 session_id,种一条会话(把现有
  /// 单会话平滑升级为「会话 #1」);并把缓存中 session_id 为 NULL 的存量行回填
  /// 到当前会话,避免历史消息丢失。
  Future<void> _ensureSessionsLoaded() async {
    if (_sessionsLoaded) return;
    await _sessions.load();
    final wasEmptyBeforeSeed = _sessions.sessions.isEmpty;
    await _sessions.seedFromLegacy(legacySessionId: _config.sessionId);
    if (wasEmptyBeforeSeed && _config.sessionId != null && _config.sessionId!.isNotEmpty) {
      // 种子种到 _config.sessionId;把存量消息回填到该会话。
      await _cache.backfillSession(_config.sessionId!);
    }
    _sessionsLoaded = true;
  }

  /// 把注册表状态(sessions 列表 / 当前 id / 当前展示名)同步进 ChatState。
  /// 传入 [messages] 时同时替换消息列表(connect 加载历史或切会话时用)。
  void _syncSessionState({List<LocalMessage>? messages}) {
    final cur = _sessions.currentId;
    String name;
    if (cur == kPendingSessionId) {
      name = '新会话';
    } else {
      final match = _sessions.sessions
          .where((s) => s.id == cur)
          .toList(growable: false);
      name = match.isEmpty ? ChatSession.derivedName(cur) : match.first.displayName;
    }
    state = state.copyWith(
      sessions: _sessions.sessions,
      currentSessionId: cur,
      currentSessionName: name,
      messages: messages ?? state.messages,
    );
  }

  /// 当前会话用于缓存读写的 session_id(占位会话为 kPendingSessionId='')。
  String get _cacheSessionId => _sessionsLoaded ? _sessions.currentId : kPendingSessionId;

  /// 服务端回传 session_id(首条消息后)时:若当前是占位会话,注册为新会话
  /// 并把此前插入的「无 session_id」在途消息认领到新会话。「聊天开始后从服务器
  /// 获取初始名称」即此:session_id 由服务端分配,初始展示名由其派生(前 8 位)。
  Future<void> _onServerSessionId(String sid) async {
    final wasPending = _sessions.currentId == kPendingSessionId;
    if (!wasPending && _sessions.currentId == sid) return; // 已是该会话,无需变动
    await _sessions.registerServerSession(sid,
        nowMs: DateTime.now().millisecondsSinceEpoch);
    if (wasPending) {
      // 认领首条消息发出后、服务端回传 id 之前插入的 in-flight 消息。
      await _cache.adoptOrphans(sid);
    }
    _syncSessionState();
  }

  /// 新建会话:切到占位(服务端将在首条消息后分配 id)。返回 false 表示已达 25 上限。
  Future<bool> createSession() async {
    final ok = await _sessions.beginNew();
    if (!ok) return false;
    // 清掉上一个被放弃的占位会话残留('' 消息,服务端未及认领),保证新会话干净。
    await _cache.clearSession(kPendingSessionId);
    await connect(); // 重建客户端(占位 → 不发 session_id)+ 清空消息展示
    return true;
  }

  /// 切换到指定会话:加载其本地历史 + 用该 id 重连(服务端加载该对话历史)。
  Future<void> selectSession(String id) async {
    // 离开占位会话:清掉其未发送的在途消息(服务端未及认领的 '' 行)。
    if (_sessions.currentId == kPendingSessionId) {
      await _cache.clearSession(kPendingSessionId);
    }
    final ok = await _sessions.select(id);
    if (!ok) return;
    await connect();
  }

  /// 改名(仅本地;服务端无 API-key rename 端点)。
  Future<void> renameSession(String id, String? name) async {
    final ok = await _sessions.rename(id, name);
    if (!ok) return;
    _syncSessionState();
  }

  /// 删除会话:移除注册表 + 删该会话本地消息。删的是当前会话则切到另一个(或占位)。
  Future<void> deleteSession(String id) async {
    final wasCurrent = _sessions.currentId == id;
    await _sessions.delete(id, deleteMessages: (sid) => _cache.clearSession(sid));
    if (wasCurrent) {
      await connect(); // 切到下一个会话(或占位)
    } else {
      _syncSessionState(); // 仅刷新列表
    }
  }

  /// Resolve config name to UUID by querying /api/v1/configs.
  /// Returns null if resolution fails — caller must handle.
  Future<String?> _resolveConfigId() async {
    if (_resolvedConfigId != null) return _resolvedConfigId!;
    final rawId = _config.configId;

    // Already a UUID
    if (rawId.contains('-') && rawId.length > 30) {
      _resolvedConfigId = rawId;
      return rawId;
    }

    // Look up by name
    try {
      final base = _config.serverUrl.endsWith('/')
          ? _config.serverUrl.substring(0, _config.serverUrl.length - 1)
          : _config.serverUrl;
      final uri = Uri.parse('$base/api/v1/configs');
      final res = await http.get(uri, headers: {'X-API-Key': _config.apiKey})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final configs = (json['data']?['configs'] as List?) ?? [];
        // Exact match by name or id
        for (final c in configs) {
          if (c is Map<String, dynamic>) {
            if (c['name'] == rawId || c['id'] == rawId) {
              _resolvedConfigId = c['id'] as String;
              return _resolvedConfigId!;
            }
          }
        }
        // Case-insensitive match
        final lowerId = rawId.toLowerCase();
        for (final c in configs) {
          if (c is Map<String, dynamic>) {
            final name = (c['name'] as String?) ?? '';
            if (name.toLowerCase() == lowerId) {
              _resolvedConfigId = c['id'] as String;
              return _resolvedConfigId!;
            }
          }
        }
        // Not found
        final names = configs.map((c) => c['name'] ?? '?').join(', ');
        state = state.copyWith(
          connectionState: ConnState.disconnected,
          errorMessage: '配置 "$rawId" 未找到\n可用: $names',
        );
        return null;
      } else {
        state = state.copyWith(
          connectionState: ConnState.disconnected,
          errorMessage: '获取配置列表失败: HTTP ${res.statusCode}',
        );
        return null;
      }
    } catch (e) {
      state = state.copyWith(
        connectionState: ConnState.disconnected,
        errorMessage: '无法连接服务器: $e',
      );
      return null;
    }
  }

  Future<void> connect() async {
    // Cancel any subscriptions/listeners from a previous connect() call.
    // Without this, every reconnect leaks a new Connectivity subscription,
    // and after a few reconnects multiple listeners fire connect() at once →
    // racing clients and dropped/duplicated messages.
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _eventSub?.cancel();
    _eventSub = null;

    try {
      // Clear previous errors
      state = state.copyWith(errorMessage: null);
      // 多会话:首启加载注册表 + 旧单会话种子 + 把存量消息回填到当前会话(仅一次)。
      await _ensureSessionsLoaded();
      final cur = _sessions.currentId; // 真实 id 或 kPendingSessionId(新会话占位)
      // 镜像到 config:真实 id 写回(供 session_id 事件及旧路径读),占位写空串。
      await _config.setSessionId(cur == kPendingSessionId ? '' : cur);
      // 加载当前会话的本地历史(占位会话返回空)。列表交给 SliverList 懒渲染,
      // 首屏只构建可见项,故即便历史很长内存与渲染仍可控。
      _historyOffset = 0;
      final history = await _cache.getMessages(sessionId: cur);
      _historyOffset = history.length;
      _hasMoreHistory = false; // 已全量加载,无需向上分页
      _syncSessionState(messages: history);

      // Reset cache and resolve config name to UUID
      _resolvedConfigId = null;
      final resolvedId = await _resolveConfigId();
      if (resolvedId == null) return; // Error already set in state

      _client?.dispose();
      final mode = _config.connectionMode;
      _usingWs = mode == 'ws';
      // 占位会话用 null(session_id 不发 → 服务端分配);真实会话用该 id(服务端加载该对话历史)。
      final effectiveSid = cur == kPendingSessionId ? null : cur;

      if (_usingWs) {
        _client = AstrBotWsClient(
          serverUrl: _config.serverUrl,
          apiKey: _config.apiKey,
          username: _config.nickname,
          configId: resolvedId,
          sessionId: effectiveSid,
        );
      } else {
        _client = AstrBotSseClient(
          serverUrl: _config.serverUrl,
          apiKey: _config.apiKey,
          username: _config.nickname,
          configId: resolvedId,
          sessionId: effectiveSid,
        );
      }

      _client!.state.listen((s) {
        // G4:流式进行中连接断开(complete/end 未到)→ 把已积累文本落盘标注中断,
        // 避免孤儿气泡/丢失。complete/end 到达时 streamingText 已被清空,不触发。
        if (s == ConnState.disconnected || s == ConnState.reconnecting) {
          _flushInterruptedStream();
        }
        // Don't clear config errors when connecting
        final err = (s == ConnState.connected && state.errorMessage != null && state.errorMessage!.contains('配置'))
            ? state.errorMessage
            : (s == ConnState.connected ? null : state.errorMessage);
        state = state.copyWith(connectionState: s as ConnState, errorMessage: err);
        if (s == ConnState.connected && _pendingQueue.isNotEmpty) {
          // 检查每次发送结果:死 socket 上 sendMessage 返回 false(且已触发治愈重连),
          // 把这些消息保留在队列,等下次重连后重发,不静默丢失。
          final failed = <List<Map<String, dynamic>>>[];
          for (final msg in _pendingQueue) {
            final ok = _client!.sendMessage(msg) as bool;
            if (!ok) failed.add(msg);
          }
          _pendingQueue.clear();
          _pendingQueue.addAll(failed);
        }
      });

      _eventSub = _client!.events.listen(_handleEvent);
      await _client!.connect();

      _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
        if (!results.contains(ConnectivityResult.none) &&
            state.connectionState == ConnState.disconnected) {
          connect();
        }
      });

      // 拉取服务端自动生成的会话标题(display_name),刷新抽屉/AppBar 展示。
      // 与 webchat 一致:服务端在首轮对话后用 LLM 生成标题并存 display_name。
      _fetchServerSessionTitles();
    } catch (e) {
      state = state.copyWith(errorMessage: '连接失败: $e');
    }
  }

  /// 拉取服务端会话标题(PlatformSession.display_name)并合并进本地注册表的
  /// serverName(不覆盖用户自定义 name)。供 connect 末尾、抽屉打开、首轮回合后调用。
  /// 失败静默(标题是展示增强,非关键路径)。
  Future<void> _fetchServerSessionTitles() async {
    if (_config.apiKey.isEmpty || _config.serverUrl.isEmpty) return;
    try {
      final base = _config.serverUrl.endsWith('/')
          ? _config.serverUrl.substring(0, _config.serverUrl.length - 1)
          : _config.serverUrl;
      final uri = Uri.parse(
          '$base/api/v1/chat/sessions?username=${Uri.encodeQueryComponent(_config.nickname)}&page=1&page_size=100');
      final res = await http
          .get(uri, headers: {'X-API-Key': _config.apiKey})
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (json['data']?['sessions'] as List?) ?? [];
      final map = <String, String?>{};
      for (final s in list) {
        if (s is Map) {
          final id = s['session_id'] as String?;
          if (id != null) map[id] = s['display_name'] as String?;
        }
      }
      final changed = await _sessions.mergeServerTitles(map);
      if (changed) _syncSessionState();
    } catch (_) {
      // 网络异常等:静默,下次 connect/抽屉打开再试。
    }
  }

  /// 抽屉打开时由 UI 调用,刷新会话标题(服务端可能刚生成完)。
  Future<void> refreshSessionTitles() => _fetchServerSessionTitles();

  /// 一轮流式结束后:若当前会话尚无服务端标题,延迟取一次(complete 与 end
  /// 可能都触发,故取消重排,最终只在最后一次后 4s 取一次)。有标题后不再调度。
  void _scheduleTitleRefreshIfNeeded() {
    if (_sessions.currentHasServerName) return;
    _titleRefreshTimer?.cancel();
    _titleRefreshTimer = Timer(const Duration(seconds: 4), _fetchServerSessionTitles);
  }

  void sendText(String text) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final List<Map<String, dynamic>> msgParts = [{'type': 'plain', 'text': text}];

    final localMsg = LocalMessage(
      msgType: 'text',
      content: text,
      isFromMe: true,
      status: MessageStatus.pending,
      createdAt: now,
    );
    state = state.copyWith(
      messages: [...state.messages, localMsg],
      toolCalls: [],
      toolResults: [],
    );
    _cache.insertMessage(localMsg, sessionId: _cacheSessionId);
    _dispatchText(createdAt: now, text: text, msgParts: msgParts);
  }

  /// 把一条文本消息真正发到线上(新发与重发共用)。
  /// - 已连接:发送;SSE 记在途用于失败关联;WS 死 socket 则保持 pending 入队等重连。
  /// - 未连接:入 pendingQueue,重连后由 drain 重发。
  void _dispatchText({
    required int createdAt,
    required String text,
    required List<Map<String, dynamic>> msgParts,
  }) {
    final conn = state.connectionState;
    if (conn == ConnState.connected && _client != null) {
      final ok = _client!.sendMessage(msgParts) as bool;
      if (_usingWs) {
        if (ok) {
          state = state.copyWith(
            messages: state.messages
                .map((m) => m.createdAt == createdAt
                    ? m.copyWith(status: MessageStatus.sent)
                    : m)
                .toList(),
          );
        } else {
          // WS 死 socket:_forceReconnect 已治愈连接;消息保持 pending 入队,
          // 重连成功后由现有 pending drain 重发,不丢失。
          _pendingQueue.add(msgParts);
        }
      } else {
        // SSE:发送恒返回 true(乐观),标 sent;失败经 error 事件回传再翻 error。
        _inflightTextCreatedAt = createdAt;
        state = state.copyWith(
          messages: state.messages
              .map((m) => m.createdAt == createdAt
                  ? m.copyWith(status: MessageStatus.sent)
                  : m)
              .toList(),
        );
      }
    } else {
      _pendingQueue.add(msgParts);
      if (_client == null) {
        state = state.copyWith(errorMessage: '客户端未初始化');
      }
    }
  }

  /// 重发失败的文本消息(用户在失败文本气泡上点击重试)。
  Future<void> retryTextSend(int createdAt) async {
    final idx = state.messages
        .indexWhere((m) => m.createdAt == createdAt && m.isFromMe);
    if (idx < 0) return;
    final text = state.messages[idx].content;
    if (text == null || text.isEmpty) return;
    // 复位为 pending,供 UI 反馈。
    state = state.copyWith(messages: setMessagePending(state.messages, createdAt));
    final msgParts = <Map<String, dynamic>>[{'type': 'plain', 'text': text}];
    _dispatchText(createdAt: createdAt, text: text, msgParts: msgParts);
  }

  /// Create an "uploading" placeholder bubble for an outgoing media message
  /// before the upload starts. Returns the message's createdAt (used as a
  /// handle to update progress / finalize / mark failure).
  int createPendingMedia({required String msgType, String? localPath, String? content}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msg = LocalMessage(
      msgType: msgType,
      content: content,
      localPath: localPath,
      isFromMe: true,
      status: MessageStatus.uploading,
      uploadProgress: 0.0,
      createdAt: now,
    );
    state = state.copyWith(messages: [...state.messages, msg]);
    _cache.upsert(msg, sessionId: _cacheSessionId);
    return now;
  }

  void updateUploadProgress(int createdAt, double progress) {
    final msgs = [...state.messages];
    for (int i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].createdAt == createdAt && msgs[i].isFromMe) {
        msgs[i] = msgs[i].copyWith(uploadProgress: progress.clamp(0.0, 1.0));
        state = state.copyWith(messages: msgs);
        return;
      }
    }
  }

  /// Upload finished: stamp the real attachment_id, mark sent, and dispatch the
  /// actual chat message (image/record/file part) over the wire.
  void finalizeMediaSend(int createdAt, String attachmentId, String msgType) {
    final msgs = [...state.messages];
    for (int i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].createdAt == createdAt && msgs[i].isFromMe) {
        msgs[i] = msgs[i].copyWith(
          attachmentId: attachmentId,
          status: MessageStatus.sent,
          uploadProgress: null,
        );
        state = state.copyWith(messages: msgs);
        _cache.upsert(msgs[i], sessionId: _cacheSessionId);
        break;
      }
    }
    final partType = msgType == 'voice' ? 'record' : msgType;
    final parts = <Map<String, dynamic>>[{'type': partType, 'attachment_id': attachmentId}];
    if (state.connectionState == ConnState.connected && _client != null) {
      _client!.sendMessage(parts);
    } else {
      _pendingQueue.add(parts);
    }
  }

  void failMediaUpload(int createdAt) {
    final msgs = [...state.messages];
    for (int i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].createdAt == createdAt && msgs[i].isFromMe) {
        msgs[i] = msgs[i].copyWith(status: MessageStatus.error, uploadProgress: null);
        state = state.copyWith(messages: msgs);
        _cache.upsert(msgs[i], sessionId: _cacheSessionId);
        return;
      }
    }
  }

  /// 重发失败的媒体消息(用户在失败气泡上点击重试)。复用其 localPath
  /// 重新走上传→finalize 流程。仅对保留了 localPath 的失败消息有效。
  Future<void> retryMediaSend(int createdAt, String msgType, String? localPath, String? content) async {
    if (localPath == null || localPath.isEmpty) return;
    final file = File(localPath);
    if (!await file.exists()) return; // 源文件已不在,无法重发
    // 复位为上传中态,供 UI 显示进度。
    final msgs = [...state.messages];
    for (int i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].createdAt == createdAt && msgs[i].isFromMe) {
        msgs[i] = msgs[i].copyWith(status: MessageStatus.uploading, uploadProgress: 0.0);
        state = state.copyWith(messages: msgs);
        break;
      }
    }
    String mime;
    switch (msgType) {
      case 'voice': mime = 'audio/wav'; break;
      case 'image': mime = 'image/jpeg'; break;
      default:
        mime = (content != null && content.toLowerCase().endsWith('.pdf'))
            ? 'application/pdf' : 'application/octet-stream';
    }
    final fs = FileService(serverUrl: _config.serverUrl, apiKey: _config.apiKey);
    final result = await fs.uploadFile(file, mime, onProgress: (s, t) {
      updateUploadProgress(createdAt, t > 0 ? s / t : 0);
    });
    final id = result['attachment_id'] as String?;
    if (id != null) {
      finalizeMediaSend(createdAt, id, msgType);
    } else {
      failMediaUpload(createdAt);
    }
  }

  /// 生成中途断网兜底:若 streamingText 非空且本轮未完成(complete/end 会清空它),
  /// 落盘为一条带「中断」后缀的 bot 文本消息。
  void _flushInterruptedStream() {
    final interrupted = interruptedBotText(state.streamingText);
    if (interrupted == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final botMsg = LocalMessage(
      msgType: 'text',
      content: interrupted,
      isFromMe: false,
      status: MessageStatus.sent,
      createdAt: now,
    );
    _cache.upsertBotText(botMsg, sessionId: _cacheSessionId);
    state = state.copyWith(
      messages: [...state.messages, botMsg],
      streamingText: null,
    );
  }

  void _handleEvent(ChatEvent event) {
    final now = DateTime.now().millisecondsSinceEpoch;

    if (event.isToolCall) {
      try {
        final json = jsonDecode(event.data ?? '{}') as Map<String, dynamic>;
        final tc = ToolCall.fromJson(json);
        state = state.copyWith(toolCalls: [...state.toolCalls, tc]);
      } catch (_) {}
      return;
    }

    if (event.isToolCallResult) {
      try {
        final json = jsonDecode(event.data ?? '{}') as Map<String, dynamic>;
        final tr = ToolResult.fromJson(json);
        state = state.copyWith(toolResults: [...state.toolResults, tr]);
      } catch (_) {}
      return;
    }

    switch (event.type) {
      case 'session_id':
        if (event.sessionId != null) {
          _onServerSessionId(event.sessionId!); // fire-and-forget(与缓存写入一致)
        }
        break;

      case 'plain':
        if (!_usingWs) _inflightTextCreatedAt = null;
        final currentStreaming = state.streamingText ?? '';
        state = state.copyWith(streamingText: currentStreaming + (event.data ?? ''));
        break;

      case 'image':
      case 'record':
      case 'file':
      case 'video':
        // Raw media events carry only a server filename ([IMAGE]uuid.ext), which
        // is NOT downloadable with an API key on v4.25.5 (the by-filename
        // endpoint /api/chat/get_file requires a dashboard JWT). So we leave
        // attachmentId empty here; the attachment_saved event — sent right
        // after by the server — supplies the real attachment_id that
        // /api/v1/file accepts. The filename is kept in `content` for display.
        {
          final d = event.data ?? '';
          final filename = d
              .replaceFirst('[IMAGE]', '')
              .replaceFirst('[RECORD]', '')
              .replaceFirst('[FILE]', '')
              .replaceFirst('[VIDEO]', '')
              .split('|')
              .first
              .trim();
          final cat = _mediaCategory(event.type);
          // 去重:若已存在同类别、同文件名、近期且尚无 attachment_id 的占位消息,
          // 视为服务端重复投递的 raw 事件,跳过——避免历史里出现两条(一条可播、一条卡死)。
          final dup = state.messages.any((m) =>
              !m.isFromMe &&
              m.attachmentId == null &&
              _mediaCategory(m.msgType) == cat &&
              (now - m.createdAt).abs() < 10000 &&
              m.content == (filename.isNotEmpty ? filename : null));
          if (!dup) {
            final botMsg = LocalMessage(
              msgType: event.type,
              content: filename.isNotEmpty ? filename : null,
              isFromMe: false,
              status: MessageStatus.sent,
              createdAt: now,
            );
            state = state.copyWith(messages: [...state.messages, botMsg]);
            _cache.upsert(botMsg, sessionId: _cacheSessionId);
          }
        }
        break;

      case 'attachment_saved':
        // 携带真实 attachment_id 的事件。把 id 贴到已有的 raw 占位消息上(按媒体类别
        // 归一化匹配 record/audio/voice 等,且只匹配尚无 id 的占位),避免新建导致
        // 重复气泡;找不到占位时才新建。
        try {
          final json = jsonDecode(event.data ?? '{}') as Map<String, dynamic>;
          final id = json['id'] as String?;
          final mediaType = json['type'] as String? ?? 'file';
          if (id != null) {
            final cat = _mediaCategory(mediaType);
            final msgs = [...state.messages];
            int target = -1;
            for (int i = msgs.length - 1; i >= 0; i--) {
              final m = msgs[i];
              if (!m.isFromMe &&
                  m.attachmentId == null &&
                  _mediaCategory(m.msgType) == cat) {
                target = i;
                break;
              }
            }
            final already = msgs.any((m) => m.attachmentId == id);
            if (target >= 0) {
              msgs[target] = msgs[target].copyWith(attachmentId: id);
              _cache.upsert(msgs[target], sessionId: _cacheSessionId);
            } else if (!already) {
              // 服务端未先发 raw 占位、直接发 saved 时新建。同 attachmentId
              // 已存在(重复投递)则跳过,避免同一条媒体二次入列。
              final created = LocalMessage(
                msgType: mediaType, attachmentId: id,
                isFromMe: false, status: MessageStatus.sent, createdAt: now,
              );
              msgs.add(created);
              _cache.upsert(created, sessionId: _cacheSessionId);
            }
            // 自动播放:bot 语音拿到 attachmentId 后入队(开关开时)。
            if (!already &&
                _playback != null && _config.autoPlayVoice && cat == 'audio') {
              final targetMsg = target >= 0
                  ? msgs[target]
                  : msgs.last;
              _playback!.enqueue(targetMsg);
            }
            state = state.copyWith(messages: msgs);
          }
        } catch (_) {}
        break;

      case 'complete':
        _inflightTextCreatedAt = null;
        if (state.streamingText != null && state.streamingText!.isNotEmpty) {
          final botMsg = LocalMessage(
            msgType: 'text',
            content: state.streamingText,
            isFromMe: false,
            status: MessageStatus.sent,
            createdAt: now,
          );
          // 按内容去重持久化:complete 与 end 可能各自触发(或重连重投递),
          // 二者 createdAt 不同毫秒,普通 upsert 撞不上,故用内容+时间窗去重。
          _cache.upsertBotText(botMsg, sessionId: _cacheSessionId);
          state = state.copyWith(
            messages: [...state.messages, botMsg],
            streamingText: null,
            toolCalls: [],
            toolResults: [],
          );
        }
        _scheduleTitleRefreshIfNeeded();
        break;

      case 'end':
        _inflightTextCreatedAt = null;
        if (state.streamingText != null && state.streamingText!.isNotEmpty) {
          final botMsg = LocalMessage(
            msgType: 'text',
            content: state.streamingText,
            isFromMe: false,
            status: MessageStatus.sent,
            createdAt: now,
          );
          _cache.upsertBotText(botMsg, sessionId: _cacheSessionId);
          state = state.copyWith(
            messages: [...state.messages, botMsg],
            streamingText: null,
            toolCalls: [],
            toolResults: [],
          );
        }
        _scheduleTitleRefreshIfNeeded();
        break;

      case 'error':
        // SSE 在途文本失败:把对应消息翻成 error(供点击重发)。
        if (!_usingWs && _inflightTextCreatedAt != null) {
          final inflight = _inflightTextCreatedAt!;
          _inflightTextCreatedAt = null;
          final msgs = markOutboundError(state.messages, inflight);
          for (final m in msgs) {
            if (m.createdAt == inflight && m.isFromMe) _cache.upsert(m, sessionId: _cacheSessionId);
          }
          state = state.copyWith(messages: msgs);
        }
        state = state.copyWith(errorMessage: event.data ?? '未知错误');
        break;
    }
  }

  void clearError() => state = state.copyWith(errorMessage: null);

  Future<bool> loadMoreHistory() async {
    if (!_hasMoreHistory) return false;
    final older = await _cache.getMessages(
        sessionId: _cacheSessionId, limit: 20, offset: _historyOffset);
    if (older.isEmpty) {
      _hasMoreHistory = false;
      return false;
    }
    _historyOffset += older.length;
    // Prepend older messages before current ones
    final msgs = [...older, ...state.messages];
    // Only update toolCalls/toolResults if we have streaming content
    state = state.copyWith(messages: msgs);
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventSub?.cancel();
    _connectivitySub?.cancel();
    _titleRefreshTimer?.cancel();
    _client?.dispose();
    super.dispose();
  }
}
