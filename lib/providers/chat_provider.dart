// lib/providers/chat_provider.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/botapi_event.dart';
import '../models/message.dart';
import '../models/account.dart';
import '../services/botapi_client.dart';
import '../services/botapi_http.dart';
import '../services/audio_playback_service.dart';
import '../services/cache_service.dart';
import '../services/config_service.dart';
import '../services/account_store.dart';
import '../util/stream_text.dart';
import 'config_provider.dart';

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  final config = ref.read(configServiceProvider);
  return ChatNotifier(config);
});

String _mediaCategory(String t) {
  switch (t) {
    case 'voice':
    case 'audio':
    case 'record':
      return 'audio';
    case 'image':
    case 'photo':
      return 'image';
    default:
      return t;
  }
}

class ChatState {
  final List<LocalMessage> messages;
  final ConnState connectionState;
  final String? streamingText;
  final String? streamingThinking;
  final String? errorMessage;
  final bool autoPlayVoice;
  final List<Account> accounts;
  final String currentAccountId;
  final String currentAccountName;

  const ChatState({
    this.messages = const [],
    this.connectionState = ConnState.disconnected,
    this.streamingText,
    this.streamingThinking,
    this.errorMessage,
    this.autoPlayVoice = false,
    this.accounts = const [],
    this.currentAccountId = kNoAccount,
    this.currentAccountName = '未选择账户',
  });

  ChatState copyWith({
    List<LocalMessage>? messages,
    ConnState? connectionState,
    String? streamingText,
    String? streamingThinking,
    String? errorMessage,
    bool? autoPlayVoice,
    List<Account>? accounts,
    String? currentAccountId,
    String? currentAccountName,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        connectionState: connectionState ?? this.connectionState,
        streamingText: streamingText,
        streamingThinking: streamingThinking,
        errorMessage: errorMessage,
        autoPlayVoice: autoPlayVoice ?? this.autoPlayVoice,
        accounts: accounts ?? this.accounts,
        currentAccountId: currentAccountId ?? this.currentAccountId,
        currentAccountName: currentAccountName ?? this.currentAccountName,
      );
}

class ChatNotifier extends StateNotifier<ChatState> with WidgetsBindingObserver {
  final ConfigService _config;
  final CacheService _cache = CacheService();
  final AccountStore _accounts;
  bool _accountsLoaded = false;
  BotApiClient? _client;
  BotApiHttp? _http;
  StreamSubscription<BotApiEvent>? _eventSub;
  StreamSubscription<ConnState>? _stateSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  // 未连接时暂存的待发消息（文本/媒体 fileIds），connected 后 drain。
  final List<_PendingSend> _pendingQueue = [];
  AudioPlaybackNotifier? _playback;
  // SSE 在途：当前正在等服务端响应的「我发出」文本消息的 createdAt（用于失败关联）。
  int? _inflightTextCreatedAt;

  // 定时对齐：周期性用 since=本地最大 server_id 轻量拉取，有新行就合并补齐，
  // 兜底 SSE 静默丢消息。仅在前台运行（后台靠 SSE 实时 + 看门狗）。
  Timer? _alignTimer;
  static const Duration _alignInterval = Duration(seconds: 60);
  bool _resumed = true;
  // 收到 bot 回复(final)后 2s 触发一次增量对齐：botapi 的 SSE 只推 bot 回复、
  // 不回显用户消息,故从其它设备/curl 发的用户消息需靠历史对齐同步。挂在回复后
  // 触发,使其紧随回复到达(而非等 60s 定时)。
  Timer? _replyCatchupTimer;

  ChatNotifier(this._config)
      : _accounts = AccountStore(PrefsAccountStorage(_config.prefs)),
        super(ChatState(autoPlayVoice: _config.autoPlayVoice)) {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed) _onAppResumed();
  }

  void _onAppResumed() {
    Future.delayed(const Duration(milliseconds: 600), () async {
      if (!mounted) return;
      if (state.connectionState == ConnState.connected) {
        // 流仍连：但可能「假活」（OS 后台冻结期间 SSE 静默、onDone 未触发、
        // 状态仍报 connected）。无条件合并一次历史，把冻结期间错过的文本捞回。
        await _catchupHistory();
      } else {
        connect();
      }
    });
  }

  /// 拉服务端历史并合并入库（按 server_id 去重），刷新展示，并更新 SSE 游标。
  /// 不动 SSE 流本身。用于回前台补漏（流仍连但可能假活）。
  Future<void> _catchupHistory() async {
    final acc = _currentAccount;
    final http = _http;
    if (acc == null || http == null) return;
    try {
      final hist = await http.fetchHistory(since: 0);
      await _cache.mergeHistory(hist.messages, accountId: acc.id);
      final cursor = await _cache.maxServerId(acc.id);
      _client?.sinceCursor = cursor; // 供下次 SSE 重连用更准的游标
      final refreshed = await _cache.getMessages(accountId: acc.id);
      if (mounted) _syncAccountState(messages: refreshed);
    } catch (_) {
      // 网络异常等：静默，下次再试。
    }
  }

  /// 启动定时对齐检查（前台 + 已连接时每 60s 一次）。
  void _startAlignCheck() {
    _alignTimer?.cancel();
    _alignTimer = Timer.periodic(_alignInterval, (_) => _alignCheck());
  }

  /// 用 since=本地最大 server_id 轻量拉取：返回为空即已对齐；有新行则合并补齐。
  /// 仅前台运行（后台靠 SSE 实时 + 看门狗，且进程冻结时 Timer 本就不触发）。
  Future<void> _alignCheck() async {
    if (!mounted || !_resumed) return;
    if (state.connectionState != ConnState.connected) return;
    final acc = _currentAccount;
    final http = _http;
    if (acc == null || http == null) return;
    try {
      final localMax = await _cache.maxServerId(acc.id);
      final res = await http.fetchHistory(since: localMax);
      if (res.messages.isEmpty) return; // 已对齐
      await _cache.mergeHistory(res.messages, accountId: acc.id);
      _client?.sinceCursor = await _cache.maxServerId(acc.id);
      final refreshed = await _cache.getMessages(accountId: acc.id);
      if (mounted) _syncAccountState(messages: refreshed);
    } catch (_) {
      // 静默：下次 tick 再试。
    }
  }

  void attachPlayback(AudioPlaybackNotifier p) => _playback = p;

  bool get autoPlayVoice => state.autoPlayVoice;

  Future<void> setAutoPlayVoice(bool v) async {
    await _config.setAutoPlayVoice(v);
    state = state.copyWith(autoPlayVoice: v);
  }

  Future<void> _ensureAccountsLoaded() async {
    if (_accountsLoaded) return;
    await _accounts.load();
    await _cache.wipeIfFlagged(_config.prefs);
    _accountsLoaded = true;
  }

  void _syncAccountState({List<LocalMessage>? messages}) {
    final cur = _accounts.currentId;
    String name;
    if (cur == kNoAccount) {
      name = '未选择账户';
    } else {
      final match = _accounts.accounts.where((a) => a.id == cur).toList();
      name = match.isEmpty ? 'Bot' : match.first.displayName;
    }
    state = state.copyWith(
      accounts: _accounts.accounts,
      currentAccountId: cur,
      currentAccountName: name,
      messages: messages ?? state.messages,
    );
  }

  String get _cacheAccountId =>
      _accountsLoaded ? _accounts.currentId : kNoAccount;

  Account? get _currentAccount {
    final cur = _accounts.currentId;
    if (cur == kNoAccount) return null;
    final m = _accounts.accounts.where((a) => a.id == cur);
    return m.isEmpty ? null : m.first;
  }

  Future<void> connect() async {
    _connectivitySub?.cancel();
    _connectivitySub = null;
    _eventSub?.cancel();
    _eventSub = null;
    _stateSub?.cancel();
    _stateSub = null;
    _alignTimer?.cancel();
    _alignTimer = null;
    await _client?.dispose();
    _client = null;

    try {
      state = state.copyWith(
          errorMessage: null,
          streamingText: null,
          streamingThinking: null);
      await _ensureAccountsLoaded();
      final acc = _currentAccount;
      if (acc == null) {
        state = state.copyWith(
            connectionState: ConnState.disconnected,
            errorMessage: '未添加账户，请点击左上角菜单添加');
        _syncAccountState();
        return;
      }
      _http = BotApiHttp(serverUrl: acc.serverUrl, token: acc.token);

      // 加载本地历史
      final history = await _cache.getMessages(accountId: acc.id);
      _syncAccountState(messages: history);

      // 校验 token（带 transient 重试，克服冷启动 DNS 解析失败）
      final ok = await _http!.auth();
      if (!ok) {
        state = state.copyWith(
            connectionState: ConnState.disconnected,
            errorMessage: 'token 无效或服务器不可达，请在账户管理中更新');
        return;
      }

      // 拉服务端历史并合并补漏（fetchHistory 带 transient 重试）
      final hist = await _http!.fetchHistory(since: 0);
      try {
        await _cache.mergeHistory(hist.messages, accountId: acc.id);
      } catch (_) {
        // 合并失败不阻塞 SSE：实时流仍可工作，下次重连再补。
      }
      final cursor = await _cache.maxServerId(acc.id);
      final refreshed = await _cache.getMessages(accountId: acc.id);
      _syncAccountState(messages: refreshed);

      // 开 SSE 流
      _client = BotApiClient(serverUrl: acc.serverUrl, token: acc.token);
      _stateSub = _client!.state.listen((s) {
        if (s == ConnState.disconnected || s == ConnState.reconnecting) {
          _flushInterruptedStream();
        }
        final err = (s == ConnState.connected) ? null : state.errorMessage;
        state = state.copyWith(connectionState: s, errorMessage: err);
        if (s == ConnState.connected && _pendingQueue.isNotEmpty) {
          final pending = List<_PendingSend>.from(_pendingQueue);
          _pendingQueue.clear();
          for (final p in pending) {
            _dispatchPending(p);
          }
        }
      });
      _eventSub = _client!.events.listen(_handleEvent);
      await _client!.connect(sinceCursor: cursor);
      _startAlignCheck();

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

  /// connected 后 drain 暂存消息。
  void _dispatchPending(_PendingSend p) {
    if (p.isText) {
      _doSendText(createdAt: p.createdAt, text: p.text, fileIds: null);
    } else {
      _doSendText(createdAt: p.createdAt, text: null, fileIds: p.fileIds);
    }
  }

  void sendText(String text) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final localMsg = LocalMessage(
      msgType: 'text',
      content: text,
      isFromMe: true,
      status: MessageStatus.pending,
      createdAt: now,
    );
    state = state.copyWith(messages: [...state.messages, localMsg]);
    _cache.insertMessage(localMsg, accountId: _cacheAccountId);
    _doSendText(createdAt: now, text: text, fileIds: null);
  }

  void _doSendText({required int createdAt, String? text, List<String>? fileIds}) {
    final http = _http;
    if (http == null) {
      _pendingQueue.add(_PendingSend(createdAt: createdAt, text: text, fileIds: fileIds));
      return;
    }
    final conn = state.connectionState;
    if (conn != ConnState.connected) {
      _pendingQueue.add(_PendingSend(createdAt: createdAt, text: text, fileIds: fileIds));
      return;
    }
    if (text != null) _inflightTextCreatedAt = createdAt;
    http.sendMessage(text: text, fileIds: fileIds).then((mid) {
      if (!mounted) return;
      if (mid == null) {
        // 发送失败：标记 error（可重发）
        final msgs = _markOutboundError(state.messages, createdAt);
        state = state.copyWith(messages: msgs, errorMessage: '发送失败');
        for (final m in msgs) {
          if (m.createdAt == createdAt && m.isFromMe) {
            _cache.upsert(m, accountId: _cacheAccountId);
          }
        }
      } else {
        // 成功：标 sent
        state = state.copyWith(
            messages: state.messages
                .map((m) => (m.createdAt == createdAt && m.isFromMe)
                    ? m.copyWith(status: MessageStatus.sent)
                    : m)
                .toList());
        // 用户文本消息贴 server_id 在下次 connect 的 history 合并时完成。
        if (text != null) _inflightTextCreatedAt = null;
      }
    });
  }

  Future<void> retryTextSend(int createdAt) async {
    final idx = state.messages
        .indexWhere((m) => m.createdAt == createdAt && m.isFromMe);
    if (idx < 0) return;
    final text = state.messages[idx].content;
    if (text == null || text.isEmpty) return;
    state = state.copyWith(messages: _setMessagePending(state.messages, createdAt));
    _doSendText(createdAt: createdAt, text: text, fileIds: null);
  }

  // ── 媒体发送 ──

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
    _cache.upsert(msg, accountId: _cacheAccountId);
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

  /// 上传媒体文件，返回 file_id 或 null。UI 调用。
  Future<String?> uploadMedia(File file, String mime,
      {void Function(int, int)? onProgress}) async {
    final acc = _currentAccount;
    if (acc == null) return null;
    final http = _http ?? BotApiHttp(serverUrl: acc.serverUrl, token: acc.token);
    final r = await http.uploadFile(file, mime, onProgress: onProgress);
    return r?.fileId;
  }

  /// 上传完成 → 发 message(file_ids)。
  void finalizeMediaSend(int createdAt, String fileId, String msgType) {
    final msgs = [...state.messages];
    for (int i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].createdAt == createdAt && msgs[i].isFromMe) {
        msgs[i] = msgs[i].copyWith(status: MessageStatus.sent, uploadProgress: null);
        state = state.copyWith(messages: msgs);
        _cache.upsert(msgs[i], accountId: _cacheAccountId);
        break;
      }
    }
    _doSendText(createdAt: createdAt, text: null, fileIds: [fileId]);
  }

  void failMediaUpload(int createdAt) {
    final msgs = [...state.messages];
    for (int i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].createdAt == createdAt && msgs[i].isFromMe) {
        msgs[i] = msgs[i].copyWith(status: MessageStatus.error, uploadProgress: null);
        state = state.copyWith(messages: msgs);
        _cache.upsert(msgs[i], accountId: _cacheAccountId);
        return;
      }
    }
  }

  Future<void> retryMediaSend(
      int createdAt, String msgType, String? localPath, String? content) async {
    if (localPath == null || localPath.isEmpty) return;
    final file = File(localPath);
    if (!await file.exists()) return;
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
      case 'voice':
        mime = 'audio/wav';
        break;
      case 'image':
        mime = 'image/jpeg';
        break;
      default:
        mime = (content != null && content.toLowerCase().endsWith('.pdf'))
            ? 'application/pdf'
            : 'application/octet-stream';
    }
    final id = await uploadMedia(file, mime, onProgress: (s, t) {
      updateUploadProgress(createdAt, t > 0 ? s / t : 0);
    });
    if (id != null && mounted) {
      finalizeMediaSend(createdAt, id, msgType);
    } else if (mounted) {
      failMediaUpload(createdAt);
    }
  }

  // ── 事件处理 ──

  Future<void> _handleEvent(BotApiEvent event) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    if (event.isPing) return;

    if (event.isError) {
      if (event.code == 'SESSION_KICKED') {
        // 管理员强制断开：停止自动重连，等用户检查/重连。
        await _client?.dispose();
        _client = null;
        state = state.copyWith(
            connectionState: ConnState.disconnected,
            errorMessage: event.message ?? '会话已被管理员断开');
      } else {
        if (_inflightTextCreatedAt != null) {
          final inflight = _inflightTextCreatedAt!;
          _inflightTextCreatedAt = null;
          final msgs = _markOutboundError(state.messages, inflight);
          for (final m in msgs) {
            if (m.createdAt == inflight && m.isFromMe) {
              _cache.upsert(m, accountId: _cacheAccountId);
            }
          }
          state = state.copyWith(messages: msgs);
        }
        state = state.copyWith(errorMessage: event.message ?? '未知错误');
      }
      return;
    }

    if (event.isThinking) {
      final cur = state.streamingThinking ?? '';
      state = state.copyWith(streamingThinking: cur + (event.content ?? ''));
      return;
    }

    if (event.isMessage) {
      if (event.isToolStatus) {
        // 工具状态持久化为独立系统消息(与历史回放一致),final 后不清空。
        final msg = LocalMessage(
          msgType: 'tool_status',
          content: event.content ?? '',
          isFromMe: false,
          status: MessageStatus.sent,
          createdAt: now,
        );
        // 仅当 DB 真正插入才入内存列表,避免重复处理致双行(与 _commitBotText 一致)。
        final inserted = await _cache.upsertBotText(msg, accountId: _cacheAccountId);
        if (inserted) {
          state = state.copyWith(messages: [...state.messages, msg]);
        }
        return;
      }
      if (event.isMedia) {
        _handleMedia(event, now);
        return;
      }
      if (event.isStreamingText) {
        final cur = state.streamingText ?? '';
        state = state.copyWith(streamingText: accumulateStreamText(cur, event));
        return;
      }
      if (event.isFinalText) {
        final full = event.content ?? '';
        await _commitBotText(full, now);
        return;
      }
      // message text 非 streaming 非 final（罕见，按完整处理）
      if (event.type == 'text' && (event.content ?? '').isNotEmpty) {
        await _commitBotText(event.content!, now);
      }
    }
  }

  Future<void> _handleMedia(BotApiEvent event, int now) async {
    final type = event.type!;
    String? url;
    String? label;
    if (type == 'file') {
      try {
        final obj = (event.content != null && event.content!.isNotEmpty)
            ? Map<String, dynamic>.from(jsonDecode(event.content!) as Map)
            : <String, dynamic>{};
        url = obj['url'] as String?;
        label = obj['name'] as String?;
      } catch (_) {}
    } else {
      url = event.content;
    }
    final cat = _mediaCategory(type);
    final placeholder = LocalMessage(
      msgType: type,
      content: label,
      isFromMe: false,
      status: MessageStatus.sent,
      createdAt: now,
    );
    state = state.copyWith(messages: [...state.messages, placeholder]);
    _cache.upsert(placeholder, accountId: _cacheAccountId);
    if (url != null && url.isNotEmpty) {
      final localPath = await _downloadMedia(url);
      if (localPath != null && mounted) {
        final msgs = [...state.messages];
        for (int i = msgs.length - 1; i >= 0; i--) {
          if (!msgs[i].isFromMe &&
              msgs[i].createdAt == now &&
              msgs[i].msgType == type) {
            msgs[i] = msgs[i].copyWith(localPath: localPath);
            state = state.copyWith(messages: msgs);
            _cache.upsert(msgs[i], accountId: _cacheAccountId);
            if (cat == 'audio' &&
                _playback != null &&
                _config.autoPlayVoice) {
              _playback!.enqueue(msgs[i]);
            }
            break;
          }
        }
      }
    }
  }

  Future<String?> _downloadMedia(String url) async {
    final http = _http;
    if (http == null) return null;
    final f = await http.downloadByUrl(url);
    return f?.path;
  }

  Future<void> _commitBotText(String full, int now) async {
    // 先把本轮积累的思考落库为独立思考消息(与历史回放一致),再落答案。
    final thinking = state.streamingThinking;
    final list = [...state.messages];
    if (thinking != null && thinking.isNotEmpty) {
      final thinkMsg = LocalMessage(
        msgType: 'thinking',
        content: thinking,
        isFromMe: false,
        status: MessageStatus.sent,
        createdAt: now,
      );
      final tInserted = await _cache.upsertBotText(thinkMsg, accountId: _cacheAccountId);
      if (tInserted) list.add(thinkMsg);
    }
    final botMsg = LocalMessage(
      msgType: 'text',
      content: full,
      isFromMe: false,
      status: MessageStatus.sent,
      createdAt: now,
    );
    // 仅当 DB 真正插入(非重复)才入内存列表:upsertBotText 已按内容+5min 窗去重,
    // 若本回合已 commit 过(如 final 被重复处理),此处不再追加,使内存与 DB 一致,
    // 避免 UI 出现「两条一模一样→2s 历史刷新回一条」的闪烁。
    final inserted = await _cache.upsertBotText(botMsg, accountId: _cacheAccountId);
    if (inserted) list.add(botMsg);
    state = state.copyWith(
      messages: list,
      streamingText: null,
      streamingThinking: null,
    );
    _inflightTextCreatedAt = null;
    // 收到 bot 回复 → 触发增量对齐,把触发此回复的用户消息(从其它设备发出,
    // SSE 不回显)尽快同步过来。
    _scheduleReplyCatchup();
  }

  /// 去抖：2s 内多次回复只对齐一次。
  void _scheduleReplyCatchup() {
    _replyCatchupTimer?.cancel();
    _replyCatchupTimer = Timer(const Duration(seconds: 2), _catchupAfterReply);
  }

  /// 回复后增量对齐（不依赖 _resumed,因为回复刚到说明连接活着）。
  Future<void> _catchupAfterReply() async {
    if (!mounted) return;
    final acc = _currentAccount;
    final http = _http;
    if (acc == null || http == null) return;
    try {
      final localMax = await _cache.maxServerId(acc.id);
      final res = await http.fetchHistory(since: localMax);
      if (res.messages.isEmpty) return;
      await _cache.mergeHistory(res.messages, accountId: acc.id);
      _client?.sinceCursor = await _cache.maxServerId(acc.id);
      final refreshed = await _cache.getMessages(accountId: acc.id);
      if (mounted) _syncAccountState(messages: refreshed);
    } catch (_) {}
  }

  void _flushInterruptedStream() {
    final interrupted = state.streamingText;
    final thinking = state.streamingThinking;
    if ((interrupted == null || interrupted.trim().isEmpty) &&
        (thinking == null || thinking.trim().isEmpty)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final list = [...state.messages];
    if (thinking != null && thinking.trim().isNotEmpty) {
      final thinkMsg = LocalMessage(
        msgType: 'thinking',
        content: thinking,
        isFromMe: false,
        status: MessageStatus.sent,
        createdAt: now,
      );
      _cache.upsertBotText(thinkMsg, accountId: _cacheAccountId);
      list.add(thinkMsg);
    }
    if (interrupted != null && interrupted.trim().isNotEmpty) {
      final botMsg = LocalMessage(
        msgType: 'text',
        content: '$interrupted\n\n_(回复中断,请重试)_',
        isFromMe: false,
        status: MessageStatus.sent,
        createdAt: now,
      );
      _cache.upsertBotText(botMsg, accountId: _cacheAccountId);
      list.add(botMsg);
    }
    state = state.copyWith(messages: list, streamingText: null, streamingThinking: null);
  }

  // ── 账户管理 ──

  Future<bool> addAccount({
    required String serverUrl,
    required String token,
    String? label,
  }) async {
    await _ensureAccountsLoaded();
    final a = await _accounts.add(serverUrl: serverUrl, token: token, label: label);
    if (a == null) return false;
    await _config.setConfigured(true);
    await connect();
    return true;
  }

  Future<void> selectAccount(String id) async {
    await _accounts.select(id);
    await connect();
  }

  Future<void> renameAccount(String id, String? label) async {
    await _accounts.rename(id, label);
    _syncAccountState();
  }

  Future<void> updateAccountCredentials(String id,
      {required String serverUrl, required String token}) async {
    await _accounts.updateCredentials(id, serverUrl: serverUrl, token: token);
    if (id == _accounts.currentId) {
      await connect();
    } else {
      _syncAccountState();
    }
  }

  Future<void> deleteAccount(String id) async {
    final wasCurrent = _accounts.currentId == id;
    await _accounts.delete(id, deleteMessages: (aid) => _cache.clearSession(aid));
    if (_accounts.accounts.isEmpty) {
      await _config.setConfigured(false);
    }
    if (wasCurrent) {
      await connect();
    } else {
      _syncAccountState();
    }
  }

  Future<bool> loadMoreHistory() async => false; // botapi 历史在 connect 时全量加载

  void clearError() => state = state.copyWith(errorMessage: null);

  List<LocalMessage> _markOutboundError(List<LocalMessage> msgs, int createdAt) =>
      msgs
          .map((m) => (m.isFromMe && m.createdAt == createdAt)
              ? m.copyWith(status: MessageStatus.error)
              : m)
          .toList();

  List<LocalMessage> _setMessagePending(List<LocalMessage> msgs, int createdAt) =>
      msgs
          .map((m) => (m.createdAt == createdAt)
              ? m.copyWith(status: MessageStatus.pending)
              : m)
          .toList();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventSub?.cancel();
    _stateSub?.cancel();
    _connectivitySub?.cancel();
    _alignTimer?.cancel();
    _replyCatchupTimer?.cancel();
    _client?.dispose();
    super.dispose();
  }
}

class _PendingSend {
  final int createdAt;
  final String? text;
  final List<String>? fileIds;
  bool get isText => text != null;
  _PendingSend({required this.createdAt, this.text, this.fileIds});
}
