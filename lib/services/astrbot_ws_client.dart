// lib/services/astrbot_ws_client.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/chat_event.dart';

class AstrBotWsClient {
  final String serverUrl;
  final String apiKey;
  final String username;
  final String configId;
  String? sessionId;

  WebSocketChannel? _channel;
  Timer? _pingTimer;
  Timer? _pongWatchdog;
  bool _pongPending = false;
  Timer? _reconnectTimer;
  int _reconnectDelay = 1000;
  bool _disposed = false;

  // Passive liveness check. The AstrBot WS endpoint serves send + receive from
  // a single coroutine, so it cannot answer pings while it is mid-generation
  // (a long text / large file can take well over the pong timeout). Treating a
  // late pong as a dead connection would force a reconnect mid-stream and drop
  // the in-flight message. Instead we treat ANY inbound data as proof the
  // connection is alive, and only declare it dead when it has been fully
  // silent beyond [_silenceLimit].
  DateTime _lastReceivedAt = DateTime.now();
  static const Duration _pingInterval = Duration(seconds: 20);
  static const Duration _pongTimeout = Duration(seconds: 15);
  static const Duration _silenceLimit = Duration(seconds: 45);

  final _eventController = StreamController<ChatEvent>.broadcast();
  final _stateController = StreamController<ConnState>.broadcast();

  Stream<ChatEvent> get events => _eventController.stream;
  Stream<ConnState> get state => _stateController.stream;
  AstrBotWsClient({
    required this.serverUrl,
    required this.apiKey,
    required this.username,
    required this.configId,
    this.sessionId,
  });

  Future<void> connect() async {
    if (_disposed) return;
    _setState(ConnState.connecting);

    try {
      final uri = Uri.parse(serverUrl)
          .replace(scheme: serverUrl.startsWith('https') ? 'wss' : 'ws')
          .replace(path: '/api/v1/chat/ws', queryParameters: {'api_key': apiKey});

      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready.timeout(const Duration(seconds: 10));

      _setState(ConnState.connected);
      debugPrint('[WS] connected to $serverUrl');
      _reconnectDelay = 1000;
      _lastReceivedAt = DateTime.now();

      _startPing();
      _channel!.stream.listen(
        _onMessage,
        onError: (e) => _onDisconnected(),
        onDone: () => _onDisconnected(),
      );
    } catch (e) {
      debugPrint('[WS] connect failed: $e');
      _setState(ConnState.disconnected);
      _scheduleReconnect();
    }
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pongWatchdog?.cancel();
    _pongPending = false;
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      if (_disposed) return;
      // If real data has flowed recently (streaming chunks, events, or a pong),
      // the connection is alive even though the server cannot answer pings
      // while it is mid-generation. Skip the dead-connection probe entirely.
      if (DateTime.now().difference(_lastReceivedAt) < _silenceLimit) {
        return;
      }
      if (_pongPending) {
        // No pong for the previous ping AND no inbound data at all → the
        // socket is genuinely dead (or the peer is fully unresponsive).
        _forceReconnect();
        return;
      }
      _pongPending = true;
      _sendRaw(jsonEncode({'t': 'ping'}));
      _pongWatchdog?.cancel();
      _pongWatchdog = Timer(_pongTimeout, () {
        // Only a problem if still silent: business data arriving clears
        // _pongPending (see _onMessage), so this fires only on real silence.
        if (_pongPending) _forceReconnect();
      });
    });
  }

  void _forceReconnect() {
    _pongPending = false;
    _pongWatchdog?.cancel();
    try {
      _channel?.sink.close();
    } catch (_) {}
    _onDisconnected();
  }

  /// 连接仍报告 `connected`,但已超过 [_silenceLimit] 无任何入站帧 —— 典型为
  /// 进程被 OS 冻结后解冻的「僵尸」socket(冻结期间 onDone/onError 未触发,
  /// 状态仍停在 connected)。供 provider 在回前台时据此强制重连。
  /// 注意:健康生成期间入站数据持续刷新 _lastReceivedAt,不会误判为 stale。
  bool get isStale =>
      !_disposed &&
      _channel != null &&
      DateTime.now().difference(_lastReceivedAt) > _silenceLimit;

  /// 立即强制重连(用于回前台检测到僵尸连接)。复用既有 teardown + 重连路径,
  /// 该路径会发出 disconnected/reconnecting 状态,触发 provider 落盘孤儿流式文本
  /// 并按既有退避重连(同 session_id,保留上下文)。
  void forceReconnect() => _forceReconnect();

  void _onMessage(dynamic msg) {
    // Any inbound frame means the connection is alive — record it so the
    // health-check timer does not force a reconnect while the server is busy
    // generating (when it cannot answer pings).
    _lastReceivedAt = DateTime.now();
    if (msg is String) {
      try {
        final json = jsonDecode(msg) as Map<String, dynamic>;
        if (json['type'] == 'pong') {
          _pongPending = false;
          _pongWatchdog?.cancel();
          return;
        }

        final event = ChatEvent.fromJson(json);
        if (event.type == 'session_id' && event.sessionId != null) {
          sessionId = event.sessionId;
        }
        // Business data is also proof of life: clear any pending pong watchdog
        // so a long generation never trips the dead-connection probe.
        _pongPending = false;
        _pongWatchdog?.cancel();
        _eventController.add(event);
      } catch (_) {}
    }
  }

  /// 返回是否同步发送成功。WS 的 `sink.add` 同步可知成败:
  /// - 成功 → 消息已进入 socket 缓冲,视为已发送。
  /// - 死 socket → 返回 false 并触发 [_forceReconnect] 治愈连接;
  ///   调用方(ChatNotifier)据此把该消息保持 `pending` 入队,等重连后重发,
  ///   不再静默丢弃。
  bool sendMessage(List<Map<String, dynamic>> messageParts) {
    final payload = {
      't': 'send',
      'username': username,
      if (sessionId != null) 'session_id': sessionId,
      'message': messageParts,
      'config_id': configId,
    };
    if (_sendRaw(jsonEncode(payload))) {
      return true;
    }
    // Socket is closed/dead — heal the connection (治连接) + 通知调用方未送达。
    _forceReconnect();
    return false;
  }

  /// Returns false if the write could not be performed (dead socket).
  bool _sendRaw(String data) {
    if (_channel == null) return false;
    try {
      _channel!.sink.add(data);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _onDisconnected() {
    _pingTimer?.cancel();
    _pongWatchdog?.cancel();
    _pongPending = false;
    _setState(ConnState.disconnected);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _setState(ConnState.reconnecting);
    debugPrint('[WS] reconnecting in ${_reconnectDelay}ms...');
    _reconnectTimer = Timer(Duration(milliseconds: _reconnectDelay), () {
      connect();
      _reconnectDelay = (_reconnectDelay * 2).clamp(1000, 30000);
    });
  }

  void _setState(ConnState state) {
    _stateController.add(state);
  }

  Future<void> dispose() async {
    _disposed = true;
    _pingTimer?.cancel();
    _pongWatchdog?.cancel();
    _reconnectTimer?.cancel();
    await _channel?.sink.close();
    await _eventController.close();
    await _stateController.close();
  }
}
