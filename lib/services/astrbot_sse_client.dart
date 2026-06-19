// lib/services/astrbot_sse_client.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/chat_event.dart';
import '../util/reconnect.dart';
import '../util/retry.dart';

class AstrBotSseClient {
  final String serverUrl;
  final String apiKey;
  final String username;
  final String configId;
  String? sessionId;

  Timer? _healthTimer;
  Timer? _reconnectTimer;
  final ReconnectAttempt _reconnect = ReconnectAttempt();
  Timer? _idleWatchdog;
  bool _awaitingFirstByte = false;
  bool _disposed = false;

  final _eventController = StreamController<ChatEvent>.broadcast();
  final _stateController = StreamController<ConnState>.broadcast();

  Stream<ChatEvent> get events => _eventController.stream;
  Stream<ConnState> get state => _stateController.stream;

  AstrBotSseClient({
    required this.serverUrl,
    required this.apiKey,
    required this.username,
    required this.configId,
    this.sessionId,
  });

  String get _baseUrl => serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl;

  Future<void> connect() async {
    if (_disposed) return;
    _setState(ConnState.connecting);

    try {
      // 只读连通校验:GET /api/v1/configs(health check 已用),不发任何聊天
      // 消息,避免空消息污染会话上下文。session_id 由首条真实消息的 SSE
      // 响应带出。
      final uri = Uri.parse('$_baseUrl/api/v1/configs');
      final response = await http.get(uri, headers: {'X-API-Key': apiKey})
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        _onUnrecoverable();
        return;
      }
      _onConnected();
    } catch (e) {
      _scheduleReconnect();
    }
  }

  void _onConnected() {
    _reconnect.reset();
    _setState(ConnState.connected);
    _startHealthCheck();
  }

  /// 探测得到明确失败(如 4xx)且非瞬态:不再自重连,留待用户改配置后重连。
  void _onUnrecoverable() {
    _setState(ConnState.disconnected);
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    final delay = _reconnect.nextDelay(baseMs: 1000, maxMs: 30000);
    _setState(ConnState.reconnecting);
    debugPrint('[SSE] reconnecting in ${delay}ms...');
    _reconnect.recordFailure();
    _reconnectTimer = Timer(Duration(milliseconds: delay), () {
      if (!_disposed) connect();
    });
  }

  /// 仅在"已发送、尚未收到首字节"阶段启用。已开始流式输出后由首字节
  /// 处理清除——生成本身可能很长,不能用空闲看门狗误掐。
  void _startIdleWatchdog() {
    _idleWatchdog?.cancel();
    _idleWatchdog = Timer(const Duration(seconds: 30), () {
      if (_awaitingFirstByte && !_disposed) {
        _eventController.add(ChatEvent.fromJson(
            {'type': 'error', 'data': '响应超时,请重试'}));
        _awaitingFirstByte = false;
      }
    });
  }

  void _startHealthCheck() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (_disposed) return;
      try {
        final uri = Uri.parse('$_baseUrl/api/v1/configs');
        final res = await http.get(uri, headers: {'X-API-Key': apiKey})
            .timeout(const Duration(seconds: 10));
        if (res.statusCode != 200) {
          debugPrint('[SSE] health check failed: ${res.statusCode}');
          _scheduleReconnect();
        }
      } catch (e) {
        debugPrint('[SSE] health check error: $e');
        _scheduleReconnect();
      }
    });
  }

  /// SSE 发送是 fire-and-forget 的异步 POST:同步返回恒为 `true`(乐观)。
  /// 真正的失败经事件流(`error` 事件)+ 重连回传,由 ChatNotifier 的在途
  /// 跟踪把对应消息翻成 `error`。返回 bool 仅是为了与 WS 客户端签名一致。
  bool sendMessage(List<Map<String, dynamic>> messageParts) {
    _startIdleWatchdog();
    if (_disposed) {
      _eventController.add(ChatEvent.fromJson({'type': 'error', 'data': '连接已断开，请重启应用'}));
      return false;
    }
    _sendHttpMessage(messageParts).catchError((e) {
      _eventController.add(ChatEvent.fromJson({'type': 'error', 'data': '发送失败: $e'}));
    });
    return true;
  }

  Future<void> _sendHttpMessage(List<Map<String, dynamic>> messageParts) async {
    http.Client? client;
    try {
      final uri = Uri.parse('$_baseUrl/api/v1/chat');
      final body = jsonEncode({
        'username': username,
        'message': messageParts,
        'config_id': configId,
        if (sessionId != null) 'session_id': sessionId,
      });

      // Create a fresh client for each request to avoid connection-pool issues on Android
      client = http.Client();
      final request = http.Request('POST', uri);
      request.headers.addAll({
        'Content-Type': 'application/json; charset=utf-8',
        'X-API-Key': apiKey,
      });
      request.body = body;

      _awaitingFirstByte = true;
      // 首字节前重试:建立连接 / 等待响应头阶段若遇瞬态错误(连接重置/超时)
      // 则按指数退避重试,与 FileService 一致。一旦拿到 streamedResponse
      // 即视为请求已送达,后续流式解析不在重试范围内(中途断开由上层兜底)。
      final streamedResponse = await withRetry(
        () => client!.send(request).timeout(const Duration(seconds: 300)),
        isTransient: isTransientHttpError,
        maxAttempts: 3,
        delayFor: (i) => Duration(milliseconds: 1000 << i),
      );

      if (streamedResponse.statusCode != 200) {
        _eventController.add(ChatEvent.fromJson({
          'type': 'error',
          'data': 'HTTP ${streamedResponse.statusCode}',
        }));
        return;
      }

      // Parse streaming SSE response line by line
      final lineStream = streamedResponse.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      StringBuffer dataBuf = StringBuffer();
      await for (final line in lineStream) {
        if (_disposed) break;
        if (line.startsWith(':') || line.startsWith('event:')) continue;
        if (line.startsWith('data: ')) {
          dataBuf.write(line.substring(6));
          continue;
        }
        if (line.isEmpty && dataBuf.isNotEmpty) {
          final raw = dataBuf.toString();
          dataBuf = StringBuffer();
          try {
            final eventJson = jsonDecode(raw) as Map<String, dynamic>;
            final event = ChatEvent.fromJson(eventJson);
            if (event.type == 'session_id' && event.sessionId != null) {
              sessionId = event.sessionId;
            }
            _awaitingFirstByte = false;
            _idleWatchdog?.cancel();
            _eventController.add(event);
          } catch (_) {}
        }
      }
    } catch (e) {
      // 流式过程中网络中断(服务器静默断开等)→ 触发自重连恢复连接。
      _scheduleReconnect();
      _eventController.add(ChatEvent.fromJson({
        'type': 'error',
        'data': '发送失败: $e',
      }));
    } finally {
      _awaitingFirstByte = false;
      _idleWatchdog?.cancel();
      client?.close();
    }
  }

  void _setState(ConnState s) {
    _stateController.add(s);
  }

  Future<void> dispose() async {
    _disposed = true;
    _healthTimer?.cancel();
    _reconnectTimer?.cancel();
    _idleWatchdog?.cancel();
    await _eventController.close();
    await _stateController.close();
  }
}
