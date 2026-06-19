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
import '../services/astrbot_sse_client.dart';
import '../services/astrbot_ws_client.dart';
import '../services/audio_playback_service.dart';
import '../services/cache_service.dart';
import '../services/config_service.dart';
import '../services/file_service.dart';
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

  const ChatState({
    this.messages = const [],
    this.connectionState = ConnState.disconnected,
    this.streamingText,
    this.errorMessage,
    this.toolCalls = const [],
    this.toolResults = const [],
    this.autoPlayVoice = false,
  });

  ChatState copyWith({
    List<LocalMessage>? messages,
    ConnState? connectionState,
    String? streamingText,
    String? errorMessage,
    List<ToolCall>? toolCalls,
    List<ToolResult>? toolResults,
    bool? autoPlayVoice,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        connectionState: connectionState ?? this.connectionState,
        streamingText: streamingText,
        errorMessage: errorMessage,
        toolCalls: toolCalls ?? this.toolCalls,
        toolResults: toolResults ?? this.toolResults,
        autoPlayVoice: autoPlayVoice ?? this.autoPlayVoice,
      );
}

class ChatNotifier extends StateNotifier<ChatState> with WidgetsBindingObserver {
  final ConfigService _config;
  final CacheService _cache = CacheService();
  dynamic _client;
  StreamSubscription<ChatEvent>? _eventSub;
  bool _usingWs = true;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  final List<List<Map<String, dynamic>>> _pendingQueue = [];
  int _historyOffset = 0;
  bool _hasMoreHistory = true;
  AudioPlaybackNotifier? _playback;
  /// SSE 在途跟踪:当前正在等服务端响应的「我发出」文本消息的 createdAt。
  /// 仅 SSE 模式用 —— SSE 发送是 fire-and-forget,真正的失败经 error 事件回传,
  /// 靠这个把失败关联回具体消息。收到该消息的首个流式事件/complete/end 即清空。
  int? _inflightTextCreatedAt;

  ChatNotifier(this._config) : super(ChatState(autoPlayVoice: _config.autoPlayVoice)) {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (shouldReconnectOnResume(current: state, isConnected: state2IsConnected)) {
      connect();
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
      // 加载全部本地历史(撤销旧版只取最新 10 条的限制)。列表交给 SliverList
      // 懒渲染,首屏只构建可见项,故即便历史很长内存与渲染仍可控。
      _historyOffset = 0;
      final history = await _cache.getMessages();
      _historyOffset = history.length;
      _hasMoreHistory = false; // 已全量加载,无需向上分页
      if (history.isNotEmpty) {
        state = state.copyWith(messages: history);
      }

      // Reset cache and resolve config name to UUID
      _resolvedConfigId = null;
      final resolvedId = await _resolveConfigId();
      if (resolvedId == null) return; // Error already set in state

      _client?.dispose();
      final mode = _config.connectionMode;
      _usingWs = mode == 'ws';

      if (_usingWs) {
        _client = AstrBotWsClient(
          serverUrl: _config.serverUrl,
          apiKey: _config.apiKey,
          username: _config.nickname,
          configId: resolvedId,
          sessionId: _config.sessionId,
        );
      } else {
        _client = AstrBotSseClient(
          serverUrl: _config.serverUrl,
          apiKey: _config.apiKey,
          username: _config.nickname,
          configId: resolvedId,
          sessionId: _config.sessionId,
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
          for (final msg in _pendingQueue) {
            _client!.sendMessage(msg);
          }
          _pendingQueue.clear();
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
    } catch (e) {
      state = state.copyWith(errorMessage: '连接失败: $e');
    }
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
    _cache.insertMessage(localMsg);
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
    _cache.upsert(msg);
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
        _cache.upsert(msgs[i]);
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
        _cache.upsert(msgs[i]);
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
    _cache.upsertBotText(botMsg);
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
          _config.setSessionId(event.sessionId!);
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
            _cache.upsert(botMsg);
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
              _cache.upsert(msgs[target]);
            } else if (!already) {
              // 服务端未先发 raw 占位、直接发 saved 时新建。同 attachmentId
              // 已存在(重复投递)则跳过,避免同一条媒体二次入列。
              final created = LocalMessage(
                msgType: mediaType, attachmentId: id,
                isFromMe: false, status: MessageStatus.sent, createdAt: now,
              );
              msgs.add(created);
              _cache.upsert(created);
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
          _cache.upsertBotText(botMsg);
          state = state.copyWith(
            messages: [...state.messages, botMsg],
            streamingText: null,
            toolCalls: [],
            toolResults: [],
          );
        }
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
          _cache.upsertBotText(botMsg);
          state = state.copyWith(
            messages: [...state.messages, botMsg],
            streamingText: null,
            toolCalls: [],
            toolResults: [],
          );
        }
        break;

      case 'error':
        // SSE 在途文本失败:把对应消息翻成 error(供点击重发)。
        if (!_usingWs && _inflightTextCreatedAt != null) {
          final inflight = _inflightTextCreatedAt!;
          _inflightTextCreatedAt = null;
          final msgs = markOutboundError(state.messages, inflight);
          for (final m in msgs) {
            if (m.createdAt == inflight && m.isFromMe) _cache.upsert(m);
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
    final older = await _cache.getMessages(limit: 20, offset: _historyOffset);
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
    _client?.dispose();
    super.dispose();
  }
}
