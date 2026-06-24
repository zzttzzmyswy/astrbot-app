// lib/services/botapi_client.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/botapi_event.dart';
import '../util/reconnect.dart';
import '../util/retry.dart';

/// botapi SSE 流客户端：长连接 /stream 收回复，断连退避重连。
/// 发送不在本类（走 BotApiHttp.sendMessage）；本类只管收。
class BotApiClient {
  final String serverUrl;
  final String token;

  Timer? _reconnectTimer;
  final ReconnectAttempt _reconnect = ReconnectAttempt();
  bool _disposed = false;
  http.Client? _httpClient;
  int? _sinceCursor; // 重连时复用上次游标

  // 空闲看门狗：服务端每 30s 发 ping，故 90s 内无任何入站帧即可判定连接
  // 已「静默僵尸」（OS 后台冻结等，onDone/onError 未触发、状态仍报 connected）。
  // 届时强制关闭 http client 以打断流，触发既有重连路径（带 since 游标补漏）。
  DateTime _lastReceivedAt = DateTime.now();
  Timer? _idleWatchdog;
  static const Duration _idleCheckInterval = Duration(seconds: 30);
  static const Duration _idleLimit = Duration(seconds: 90);

  final _eventController = StreamController<BotApiEvent>.broadcast();
  final _stateController = StreamController<ConnState>.broadcast();

  Stream<BotApiEvent> get events => _eventController.stream;
  Stream<ConnState> get state => _stateController.stream;

  BotApiClient({required this.serverUrl, required this.token});

  /// 更新 since 游标（provider 在合并历史后调用，供下次重连用更准的游标，减少冗余回放）。
  set sinceCursor(int? c) {
    if (c != null && c > 0) _sinceCursor = c;
  }

  String get _base {
    var s = serverUrl.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.endsWith('/api/v1/botapi')) return s;
    return '$s/api/v1/botapi';
  }

  /// 开 SSE 流。sinceCursor 为上次最大 history int id，用于断连补漏。
  Future<void> connect({int? sinceCursor}) async {
    if (_disposed) return;
    _sinceCursor = sinceCursor;
    _setState(ConnState.connecting);
    try {
      final uri = sinceCursor != null
          ? Uri.parse('$_base/stream?since=$sinceCursor')
          : Uri.parse('$_base/stream');
      final request = http.Request('GET', uri);
      request.headers.addAll({
        'Authorization': 'Bearer $token',
        'Accept': 'text/event-stream',
      });
      _httpClient?.close();
      _httpClient = http.Client();
      final streamedResponse = await withRetry(
        () => _httpClient!.send(request).timeout(const Duration(seconds: 300)),
        isTransient: isTransientHttpError,
        maxAttempts: 3,
        delayFor: (i) => Duration(milliseconds: 1000 << i),
      );
      if (streamedResponse.statusCode != 200) {
        // 401 等：token 问题或服务端拒绝，不再自重连，交给上层。
        _eventController.add(BotApiEvent.fromSse('error', {
          'code': 'CONNECT_FAILED',
          'message': 'HTTP ${streamedResponse.statusCode}',
        }));
        _setState(ConnState.disconnected);
        return;
      }
      _reconnect.reset();
      _lastReceivedAt = DateTime.now();
      _setState(ConnState.connected);
      _startIdleWatchdog();
      _parseStream(streamedResponse);
    } catch (e) {
      _scheduleReconnect();
    }
  }

  void _startIdleWatchdog() {
    _idleWatchdog?.cancel();
    _idleWatchdog = Timer.periodic(_idleCheckInterval, (_) {
      if (_disposed) return;
      // 仅在「已连接」且超过静默阈值时判定僵尸；重连/断开态由既有路径处理。
      if (_lastState == ConnState.connected &&
          DateTime.now().difference(_lastReceivedAt) > _idleLimit) {
        debugPrint('[BotAPI] idle watchdog: stale > ${_idleLimit.inSeconds}s, force reconnect');
        _forceReconnect();
      }
    });
  }

  /// 跟踪最近一次推入状态流的状态（供看门狗判定是否「已连接」）。
  ConnState _lastState = ConnState.disconnected;

  /// 强制重连：关闭 http client 打断 SSE 流，_parseStream 的 finally 会走既有重连。
  void _forceReconnect() {
    _idleWatchdog?.cancel();
    try {
      _httpClient?.close();
    } catch (_) {}
    // 关 client 后流会 end/throw；若未触发（极端），兜底直接排重连。
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!_disposed && _lastState != ConnState.disconnected) {
        _setState(ConnState.disconnected);
        _scheduleReconnect();
      }
    });
  }

  void _parseStream(http.StreamedResponse resp) async {
    String? eventType;
    final dataBuf = StringBuffer();
    try {
      final lines = resp.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (_disposed) break;
        _lastReceivedAt = DateTime.now(); // 任何入站帧（含 ping/空行）都视为连接活跃
        if (line.startsWith(':')) {
          // SSE 注释行，忽略
          continue;
        } else if (line.startsWith('event:')) {
          eventType = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          dataBuf.write(line.substring(5).trim());
        } else if (line.isEmpty && eventType != null) {
          final raw = dataBuf.toString();
          dataBuf.clear();
          final type = eventType;
          eventType = null;
          if (raw.isEmpty) {
            // 仅 event 行无 data（罕见）—— ping 可能 data:{}，此处空 data 视为 ping 占位
            if (type == 'ping') {
              _eventController.add(BotApiEvent.fromSse('ping', {}));
            }
            continue;
          }
          try {
            final json = jsonDecode(raw) as Map<String, dynamic>;
            _eventController.add(BotApiEvent.fromSse(type, json));
          } catch (_) {
            // data 非 JSON：忽略（不应发生）
          }
        }
      }
    } catch (_) {}
    _idleWatchdog?.cancel();
    if (!_disposed) {
      _setState(ConnState.disconnected);
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _idleWatchdog?.cancel();
    final delay = _reconnect.nextDelay(baseMs: 1000, maxMs: 30000);
    _setState(ConnState.reconnecting);
    _reconnect.recordFailure();
    debugPrint('[BotAPI] reconnecting in ${delay}ms...');
    _reconnectTimer = Timer(Duration(milliseconds: delay), () {
      if (!_disposed) connect(sinceCursor: _sinceCursor);
    });
  }

  void _setState(ConnState s) {
    _lastState = s;
    _stateController.add(s);
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _idleWatchdog?.cancel();
    _httpClient?.close();
    await _eventController.close();
    await _stateController.close();
  }
}
