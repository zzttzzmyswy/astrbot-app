# 稳定性深度优化 + UI 打磨 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 WS/SSE 双模式下全面提升连接与数据传输稳定性,并对视觉/动画/渲染做深度打磨,保持现有去重/锚定/共享播放器等关键设计不破坏。

**Architecture:** 连接可靠性收敛到两个客户端各自自重连(SSE 补齐指数退避、对齐 WS);provider 仅做 connectivity + lifecycle 兜底,避免双重重连。可重试/可单测的纯逻辑(退避序列、重试分类、生命周期策略、LRU)抽成独立小单元 TDD;连接/UI 层做集成与手动验证。稳定性任务先行,UI 任务其后。

**Tech Stack:** Flutter 3.38 / Dart ≥3.2,Riverpod 2.5(StateNotifier),http(SSE)、web_socket_channel(WS)、dio(上传/下载)、record 6 / audioplayers 6、sqflite、flutter_foreground_task 8。

参考规格:`docs/superpowers/specs/2026-06-19-stability-and-ui-polish-design.md`。

---

## 文件结构

**新建:**
- `lib/util/reconnect.dart` — 纯逻辑:退避延迟计算 `reconnectDelayMs(int attempt)` + 重连计数状态机 `ReconnectAttempt`(可单测,无 Timer 依赖)。
- `lib/util/retry.dart` — 纯逻辑:`isTransientDioError(Object)` 瞬态错误分类器 + `withRetry<T>(...)` 重试运行器(可单测)。
- `lib/util/lifecycle_reconnect.dart` — 纯逻辑:`shouldReconnectOnResume({previous, current, isConnected})` 策略(可单测)。
- `lib/util/lru_cache.dart` — 纯逻辑:有上限 LRU(基于 LinkedHashMap)(可单测)。
- `test/reconnect_test.dart`、`test/retry_test.dart`、`test/lifecycle_reconnect_test.dart`、`test/lru_cache_test.dart` — 对应单测。

**修改:**
- `lib/models/chat_event.dart:4` — `ConnState` 增 `reconnecting`。
- `lib/services/astrbot_sse_client.dart` — 自重连、只读探测、空闲看门狗、reconnecting 状态。
- `lib/services/astrbot_ws_client.dart` — 退避阶段报 `reconnecting`(对齐口径)。
- `lib/providers/chat_provider.dart` — 生命周期观察者接线 + 启动清理磁盘缓存。
- `lib/services/file_service.dart` — 上传/下载瞬态重试包装。
- `lib/services/audio_service.dart` — 暴露 amplitude 流(复用内部 recorder)。
- `lib/screens/chat_screen.dart` — 录音器泄漏修复、流式渲染隔离、Markdown LRU、聊天背景、统一强调色、顶栏图标对比度、录音浮层减繁、失败媒体重发、`reconnecting` 文案。
- `lib/main.dart` — 启动后触发 `cleanOldCache`(经 provider 或直接),非阻塞。

---

## 阶段 A:稳定性 —— 纯逻辑单元(TDD)

### Task A1: 重连退避序列 (`lib/util/reconnect.dart`)

**Files:**
- Create: `lib/util/reconnect.dart`
- Test: `test/reconnect_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// test/reconnect_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/util/reconnect.dart';

void main() {
  group('reconnectDelayMs', () {
    test('第 0 次失败后延迟 1000ms(基数)', () {
      expect(reconnectDelayMs(0, baseMs: 1000, maxMs: 30000), 1000);
    });
    test('指数退避 1→2→4→8 秒', () {
      expect(reconnectDelayMs(1, baseMs: 1000, maxMs: 30000), 2000);
      expect(reconnectDelayMs(2, baseMs: 1000, maxMs: 30000), 4000);
      expect(reconnectDelayMs(3, baseMs: 1000, maxMs: 30000), 8000);
    });
    test('封顶 maxMs', () {
      expect(reconnectDelayMs(20, baseMs: 1000, maxMs: 30000), 30000);
    });
  });
}
```

- [ ] **Step 2: 运行测试,确认失败**

Run: `flutter test test/reconnect_test.dart`
Expected: FAIL(import 失败 / 函数未定义)。

- [ ] **Step 3: 最小实现**

```dart
// lib/util/reconnect.dart

/// 指数退避重连延迟(纯函数,无 Timer)。
/// attempt = 已经失败并即将重试的次数(0 = 第一次失败后)。
/// delay = baseMs * 2^attempt,封顶 maxMs。与 WS 现有 1s→2s→…→30s 一致。
int reconnectDelayMs(int attempt, {required int baseMs, required int maxMs}) {
  final raw = baseMs * (1 << attempt); // 2^attempt
  return raw > maxMs ? maxMs : raw;
}

/// 维护重连计数的小状态机:成功清零,失败递增并给出下次延迟。
class ReconnectAttempt {
  int _count = 0;
  int get count => _count;
  void recordFailure() => _count++;
  void reset() => _count = 0;
  int nextDelay({required int baseMs, required int maxMs}) =>
      reconnectDelayMs(_count, baseMs: baseMs, maxMs: maxMs);
}
```

- [ ] **Step 4: 运行测试,确认通过**

Run: `flutter test test/reconnect_test.dart`
Expected: PASS(3 个)。

- [ ] **Step 5: 提交**

```bash
git add lib/util/reconnect.dart test/reconnect_test.dart
git commit -m "feat(util): 指数退避重连延迟纯函数 + 单测"
```

---

### Task A2: 重试分类器与运行器 (`lib/util/retry.dart`)

**Files:**
- Create: `lib/util/retry.dart`
- Test: `test/retry_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// test/retry_test.dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:astrbot_app/util/retry.dart';

void main() {
  group('isTransientDioError', () {
    test('连接超时/发送超时/接收超时/连接错误视为瞬态', () {
      for (final t in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.connectionError,
      ]) {
        expect(isTransientDioError(DioException(requestOptions: RequestOptions(), type: t)), isTrue,
            reason: '$t 应为瞬态');
      }
    });
    test('4xx 响应与 cancel 不重试', () {
      expect(isTransientDioError(DioException(
          requestOptions: RequestOptions(), type: DioExceptionType.badResponse, response: Response(requestOptions: RequestOptions(), statusCode: 400))), isFalse);
      expect(isTransientDioError(DioException(requestOptions: RequestOptions(), type: DioExceptionType.cancel)), isFalse);
    });
    test('非 DioException 默认不重试', () {
      expect(isTransientDioError(StateError('x')), isFalse);
    });
  });

  group('withRetry', () {
    test('成功则不重试,直接返回值', () async {
      var calls = 0;
      final r = await withRetry(() async { calls++; return 42; }, isTransient: (_) => true, maxAttempts: 3, delayFor: (_) => Duration.zero);
      expect(r, 42);
      expect(calls, 1);
    });
    test('瞬态错误重试到成功', () async {
      var calls = 0;
      final r = await withRetry(() async {
        calls++;
        if (calls < 3) throw DioException(requestOptions: RequestOptions(), type: DioExceptionType.connectionTimeout);
        return 'ok';
      }, isTransient: isTransientDioError, maxAttempts: 5, delayFor: (_) => Duration.zero);
      expect(r, 'ok');
      expect(calls, 3);
    });
    test('达到上限仍失败则抛最后一次错误', () async {
      var calls = 0;
      expect(() => withRetry(() async {
        calls++;
        throw DioException(requestOptions: RequestOptions(), type: DioExceptionType.connectionError);
      }, isTransient: isTransientDioError, maxAttempts: 3, delayFor: (_) => Duration.zero), throwsA(isA<DioException>()));
      // 给 future 跑完
      await Future.delayed(Duration.zero);
    });
    test('非瞬态错误立即抛出不重试', () async {
      var calls = 0;
      expect(() => withRetry(() async {
        calls++;
        throw StateError('boom');
      }, isTransient: (_) => false, maxAttempts: 3, delayFor: (_) => Duration.zero), throwsA(isA<StateError>()));
      await Future.delayed(Duration.zero);
      expect(calls, 1);
    });
  });
}
```

- [ ] **Step 2: 运行测试,确认失败**

Run: `flutter test test/retry_test.dart`
Expected: FAIL(import 失败)。

- [ ] **Step 3: 最小实现**

```dart
// lib/util/retry.dart
import 'package:dio/dio.dart';

/// 判断一个错误是否值得重试(瞬态、网络相关)。
/// 4xx badResponse、cancel、unknown 默认不重试。
bool isTransientDioError(Object e) {
  if (e is! DioException) return false;
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionError:
      return true;
    case DioExceptionType.badResponse:
    case DioExceptionType.cancel:
    case DioExceptionType.unknown:
    case DioExceptionType.badCertificate:
      return false;
  }
}

/// 对 [action] 做最多 [maxAttempts] 次尝试。
/// 仅当 [isTransient](error) 为真才重试;否则立即抛出。
/// [delayFor] 给出第 i 次(0 起)失败后的等待,可传 Duration.zero 用于测试。
/// 成功返回值;全失败抛最后一次错误。
Future<T> withRetry<T>(
  Future<T> Function() action, {
  required bool Function(Object) isTransient,
  int maxAttempts = 3,
  required Duration Function(int attempt) delayFor,
}) async {
  Object? lastErr;
  for (int attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      return await action();
    } catch (e) {
      lastErr = e;
      if (!isTransient(e)) rethrow;
      if (attempt == maxAttempts - 1) break;
      await Future.delayed(delayFor(attempt));
    }
  }
  throw lastErr!;
}
```

- [ ] **Step 4: 运行测试,确认通过**

Run: `flutter test test/retry_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/util/retry.dart test/retry_test.dart
git commit -m "feat(util): 瞬态错误重试分类器 + 运行器 + 单测"
```

---

### Task A3: 生命周期重连策略 (`lib/util/lifecycle_reconnect.dart`)

**Files:**
- Create: `lib/util/lifecycle_reconnect.dart`
- Test: `test/lifecycle_reconnect_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// test/lifecycle_reconnect_test.dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/util/lifecycle_reconnect.dart';

void main() {
  group('shouldReconnectOnResume', () {
    test('回到前台且当前未连接 → 应重连', () {
      expect(shouldReconnectOnResume(current: AppLifecycleState.resumed, isConnected: false), isTrue);
    });
    test('回到前台但已连接 → 不重连', () {
      expect(shouldReconnectOnResume(current: AppLifecycleState.resumed, isConnected: true), isFalse);
    });
    test('非 resumed 状态 → 不触发', () {
      expect(shouldReconnectOnResume(current: AppLifecycleState.paused, isConnected: false), isFalse);
      expect(shouldReconnectOnResume(current: AppLifecycleState.hidden, isConnected: false), isFalse);
    });
  });
}
```

- [ ] **Step 2: 运行测试,确认失败**

Run: `flutter test test/lifecycle_reconnect_test.dart`
Expected: FAIL(import 失败)。

- [ ] **Step 3: 最小实现**

```dart
// lib/util/lifecycle_reconnect.dart
import 'package:flutter/widgets.dart';

/// 应用回到前台(resumed)且当前连接未建立时才需要重连。
/// 其他状态不触发——后台保活交给前台服务与心跳/存活检测。
bool shouldReconnectOnResume({required AppLifecycleState current, required bool isConnected}) {
  return current == AppLifecycleState.resumed && !isConnected;
}
```

- [ ] **Step 4: 运行测试,确认通过**

Run: `flutter test test/lifecycle_reconnect_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/util/lifecycle_reconnect.dart test/lifecycle_reconnect_test.dart
git commit -m "feat(util): 回前台重连策略 + 单测"
```

---

### Task A4: 有上限 LRU 缓存 (`lib/util/lru_cache.dart`)

**Files:**
- Create: `lib/util/lru_cache.dart`
- Test: `test/lru_cache_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// test/lru_cache_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/util/lru_cache.dart';

void main() {
  test('超过容量淘汰最早写入的键', () {
    final c = LruCache<String, int>(maxSize: 2);
    c['a'] = 1;
    c['b'] = 2;
    expect(c.containsKey('a'), isTrue);
    c['c'] = 3; // 容量 2,淘汰 a
    expect(c.containsKey('a'), isFalse);
    expect(c['b'], 2);
    expect(c['c'], 3);
  });
  test('访问(key)后该键移到最新,不被淘汰', () {
    final c = LruCache<String, int>(maxSize: 2);
    c['a'] = 1;
    c['b'] = 2;
    expect(c['a'], 1); // 访问 a
    c['c'] = 3; // 淘汰 b
    expect(c['a'], 1);
    expect(c.containsKey('b'), isFalse);
  });
  test('同名键覆盖不增容', () {
    final c = LruCache<String, int>(maxSize: 2);
    c['a'] = 1; c['a'] = 11; c['b'] = 2;
    expect(c['a'], 11);
    expect(c.length, 2);
  });
  test('清空', () {
    final c = LruCache<String, int>(maxSize: 2)..['a'] = 1;
    c.clear();
    expect(c.length, 0);
  });
}
```

- [ ] **Step 2: 运行测试,确认失败**

Run: `flutter test test/lru_cache_test.dart`
Expected: FAIL。

- [ ] **Step 3: 最小实现**

```dart
// lib/util/lru_cache.dart

/// 有序 LRU。读取/写入都会把键标记为最近使用;超出 maxSize 时淘汰最久未用。
/// 用 LinkedHashMap 的访问序(accessOrder)语义实现。
class LruCache<K, V> {
  LruCache({this.maxSize = 32});
  final int maxSize;
  final _map = <K, V>{};

  int get length => _map.length;
  bool containsKey(K key) => _map.containsKey(key);

  V? operator [](K key) {
    if (!_map.containsKey(key)) return null;
    final v = _map.remove(key)!; // 取出
    _map[key] = v; // 重新插到末尾 = 最近使用
    return v;
  }

  void operator []=(K key, V value) {
    _map.remove(key);
    _map[key] = value;
    while (_map.length > maxSize) {
      _map.remove(_map.keys.first);
    }
  }

  void clear() => _map.clear();
}
```

- [ ] **Step 4: 运行测试,确认通过**

Run: `flutter test test/lru_cache_test.dart`
Expected: PASS。

> 注:`LruCache` 用普通 `Map` + remove/re-insert 实现访问序,语义正确且无需 LinkedHashMap 特殊构造。测试应全绿。

- [ ] **Step 5: 提交**

```bash
git add lib/util/lru_cache.dart test/lru_cache_test.dart
git commit -m "feat(util): 有上限 LRU 缓存 + 单测"
```

---

## 阶段 B:稳定性 —— 连接层

### Task B1: ConnState 增 reconnecting

**Files:**
- Modify: `lib/models/chat_event.dart:4`

- [ ] **Step 1: 改枚举**

将 `lib/models/chat_event.dart` 第 4 行:

```dart
enum ConnState { disconnected, connecting, connected }
```

改为:

```dart
enum ConnState { disconnected, connecting, reconnecting, connected }
```

- [ ] **Step 2: 静态分析**

Run: `flutter analyze lib/models/chat_event.dart lib/providers/chat_provider.dart lib/screens/chat_screen.dart lib/services/astrbot_ws_client.dart lib/services/astrbot_sse_client.dart`
Expected: 0 error(`ConnState` 仅被当作值比较,新增枚举项不破坏现有 `== connected/disconnected` 判断;switch 语句代码库内未用穷举)。

- [ ] **Step 3: 提交**

```bash
git add lib/models/chat_event.dart
git commit -m "feat(model): ConnState 新增 reconnecting 语义"
```

---

### Task B2: SSE 自重连 + 只读探测 + 空闲看门狗

**Files:**
- Modify: `lib/services/astrbot_sse_client.dart`(整体)

- [ ] **Step 1: 导入新工具**

在文件顶部 import 区追加:

```dart
import '../util/reconnect.dart';
```

- [ ] **Step 2: 增加重连状态字段**

在 `class AstrBotSseClient` 字段区(第 15-16 行附近,`Timer? _healthTimer;` 旁)追加:

```dart
  Timer? _reconnectTimer;
  final ReconnectAttempt _reconnect = ReconnectAttempt();
  bool _everConnected = false;
  Timer? _idleWatchdog;
  bool _awaitingFirstByte = false;
```

- [ ] **Step 3: 把 connect() 的探测改为只读 GET**

替换现有 `connect()` 方法(第 34-90 行)中 try 块内的探测逻辑。**删掉**整段 `POST /api/v1/chat` 带 `text:''` 的测试发送与解析,改为只读校验。替换后的 `connect()` 完整方法:

```dart
  Future<void> connect() async {
    if (_disposed) return;
    _setState(ConnState.connecting);

    try {
      // 只读连通校验:GET /api/v1/configs(health check 已用),不发任何
      // 聊天消息,避免空消息污染会话上下文。session_id 由首条真实消息的
      // SSE 响应带出。
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
```

- [ ] **Step 4: 实现 _onConnected / _onUnrecoverable / _scheduleReconnect**

在 `connect()` 之后新增:

```dart
  void _onConnected() {
    _reconnect.reset();
    _everConnected = true;
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
```

- [ ] **Step 5: health-check 失败改为触发自重连**

替换 `_startHealthCheck()` 内 `if (res.statusCode != 200)` 与 `catch` 分支里的 `_setState(ConnState.disconnected);`(第 100-107 行)为 `_scheduleReconnect();`:

```dart
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
```

- [ ] **Step 6: 发送时启动空闲看门狗 + 流结束处理**

在 `sendMessage`(第 111 行)方法体首行(`if (_disposed)` 之前)加:

```dart
    _startIdleWatchdog();
```

在 `_sendHttpMessage` 内,`request` 发出前(`final streamedResponse = await ...` 之前,第 141 行之前)设:

```dart
      _awaitingFirstByte = true;
```

在解析循环里,收到首条 `data:` 行成功解析事件后(第 173 行 `_eventController.add(event);` 之后)加:

```dart
            _awaitingFirstByte = false;
            _idleWatchdog?.cancel();
```

在 `_sendHttpMessage` 的 `finally`(第 182 行)里,`client?.close();` 之前加:

```dart
      _awaitingFirstByte = false;
      _idleWatchdog?.cancel();
```

新增看门狗方法(放 `_setState` 附近):

```dart
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
```

- [ ] **Step 7: dispose 清理新定时器**

在 `dispose()`(第 191 行)内 `_healthTimer?.cancel();` 之后加:

```dart
    _reconnectTimer?.cancel();
    _idleWatchdog?.cancel();
```

- [ ] **Step 8: 静态分析**

Run: `flutter analyze lib/services/astrbot_sse_client.dart`
Expected: 0 error。

- [ ] **Step 9: 提交**

```bash
git add lib/services/astrbot_sse_client.dart
git commit -m "feat(sse): 自重连 + 只读探测(去空消息) + 空闲看门狗 + reconnecting"
```

---

### Task B3: WS 退避阶段报 reconnecting

**Files:**
- Modify: `lib/services/astrbot_ws_client.dart:177-185`(`_scheduleReconnect`)

- [ ] **Step 1: 修改 _scheduleReconnect**

将 `_scheduleReconnect()` 中 `connect();` 之前的 `_setState` 由 `disconnected`(经 `_onDisconnected` 已置)在重连定时器触发前补一次 `reconnecting`。替换 `_scheduleReconnect`(第 177-185 行)为:

```dart
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
```

> `_onDisconnected()` 仍先置 `disconnected`(第 173 行),随后 `_scheduleReconnect` 立刻覆盖为 `reconnecting`,顺序无碍:provider 与 UI 据最终 `reconnecting` 显示"重连中"。

- [ ] **Step 2: 静态分析**

Run: `flutter analyze lib/services/astrbot_ws_client.dart`
Expected: 0 error。

- [ ] **Step 3: 提交**

```bash
git add lib/services/astrbot_ws_client.dart
git commit -m "feat(ws): 退避重连阶段报 reconnecting,口径与 SSE 对齐"
```

---

### Task B4: file_service 瞬态重试

**Files:**
- Modify: `lib/services/file_service.dart`

- [ ] **Step 1: 导入重试工具**

顶部 import 区加:

```dart
import '../util/retry.dart';
```

- [ ] **Step 2: 包装上传主体**

将 `uploadFile` 中 `final response = await dio.post(...)` 及其后续解析(第 38-49 行)替换为带重试的调用。把整段 `final response = await dio.post(...)` 到 `return (json['data'] ...)` 用 `withRetry` 包裹。具体:把第 38-49 行替换为:

```dart
      final response = await withRetry(
        () => dio.post(
          '/api/v1/file',
          data: form,
          options: Options(headers: {'X-API-Key': apiKey}),
          onSendProgress: onProgress,
        ),
        isTransient: isTransientDioError,
        maxAttempts: 3,
        delayFor: (i) => Duration(milliseconds: 1000 << i),
      );
      final json = response.data is Map ? response.data as Map<String, dynamic>
          : jsonDecode(response.data.toString()) as Map<String, dynamic>;
      if (json['status'] == 'error') {
        return {'status': 'error', 'message': json['message'] ?? '上传失败'};
      }
      return (json['data'] as Map<String, dynamic>?) ?? {};
```

> `onSendProgress` 每次重试都会重新绑定,Dio 对新请求重新回调,进度条照常刷新。

- [ ] **Step 3: 包装下载主体**

将 `downloadAttachment` 中 `final response = await dio.get<List<int>>(...)`(第 74-78 行)用 `withRetry` 包裹。替换第 74-78 行为:

```dart
      final response = await withRetry(
        () => dio.get<List<int>>(
          '/api/v1/file',
          queryParameters: {'attachment_id': attachmentId},
          options: Options(headers: {'X-API-Key': apiKey}, responseType: ResponseType.bytes),
        ),
        isTransient: isTransientDioError,
        maxAttempts: 3,
        delayFor: (i) => Duration(milliseconds: 1000 << i),
      );
```

- [ ] **Step 4: 静态分析**

Run: `flutter analyze lib/services/file_service.dart`
Expected: 0 error。

- [ ] **Step 5: 提交**

```bash
git add lib/services/file_service.dart
git commit -m "feat(file): 上传/下载瞬态错误指数退避重试"
```

---

### Task B5: chat_provider 生命周期兜底 + 磁盘清理

**Files:**
- Modify: `lib/providers/chat_provider.dart`、`lib/main.dart`

- [ ] **Step 1: import**

`chat_provider.dart` 顶部加:

```dart
import 'package:flutter/widgets.dart';
import '../util/lifecycle_reconnect.dart';
import '../services/file_service.dart';
```

- [ ] **Step 2: ChatNotifier 实现 WidgetsBindingObserver**

把类声明 `class ChatNotifier extends StateNotifier<ChatState> {` 改为:

```dart
class ChatNotifier extends StateNotifier<ChatState> with WidgetsBindingObserver {
```

- [ ] **Step 3: 构造函数注册观察者**

把构造函数(第 136 行):

```dart
  ChatNotifier(this._config) : super(ChatState(autoPlayVoice: _config.autoPlayVoice));
```

改为:

```dart
  ChatNotifier(this._config) : super(ChatState(autoPlayVoice: _config.autoPlayVoice)) {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (shouldReconnectOnResume(
        current: state, isConnected: state2IsConnected)) {
      connect();
    }
  }

  bool get state2IsConnected => state.connectionState == ConnState.connected;
```

- [ ] **Step 4: dispose 移除观察者**

在 `dispose()`(第 582 行)首行加:

```dart
    WidgetsBinding.instance.removeObserver(this);
```

- [ ] **Step 5: 启动后清理磁盘缓存(非阻塞)**

在 `main.dart` 的 `main()` 中,`runApp(...)` 之前(第 24 行之前)加(忽略错误、不阻塞):

```dart
  // 非阻塞清理过期附件磁盘缓存(>7 天)。失败不影响启动。
  Future.microtask(() async {
    try {
      final config = ConfigService();
      await config.init();
      await FileService(serverUrl: config.serverUrl, apiKey: config.apiKey).cleanOldCache();
    } catch (_) {}
  });
```

并在 `main.dart` 顶部补 import:

```dart
import 'services/file_service.dart';
```

> 复用现有 `cleanOldCache()`(`file_service.dart:109`),此前定义但从未被调用。新建独立 `ConfigService` 实例仅用于读取地址/密钥,避免与 provider 实例耦合。

- [ ] **Step 6: 静态分析 + 单测回归**

Run: `flutter analyze lib/providers/chat_provider.dart lib/main.dart && flutter test`
Expected: 0 error,全部已有 + 新增单测通过。

- [ ] **Step 7: 提交**

```bash
git add lib/providers/chat_provider.dart lib/main.dart
git commit -m "feat(chat): 回前台自动重连(生命周期兜底) + 启动清理磁盘缓存"
```

---

### Task B6: audio_service 暴露 amplitude 流(修复录音器泄漏)

**Files:**
- Modify: `lib/services/audio_service.dart`、`lib/screens/chat_screen.dart:92-93,425`

- [ ] **Step 1: AudioService 暴露 amplitude 流**

在 `lib/services/audio_service.dart` 的 `AudioService` 类内(任意方法后,如 `stopRecording` 之后)加:

```dart
  /// 复用内部单一 recorder 暴露振幅流,避免调用方再 new 一个 AudioRecorder。
  Stream<Amplitude> amplitudeStream(Duration interval) {
    return _recorder.onAmplitudeChanged(interval);
  }
```

> `_recorder` 已是成员字段(第 8 行),随 `AudioService.dispose()` 一并释放。chat_screen 改用此流后不再创建新 recorder。

- [ ] **Step 2: chat_screen 改用 AudioService 的流**

`lib/screens/chat_screen.dart` 第 425 行:

```dart
    _recSub = AudioRecorder().onAmplitudeChanged(const Duration(milliseconds: 100)).listen((amp) {
```

改为:

```dart
    _recSub = _audioService.amplitudeStream(const Duration(milliseconds: 100)).listen((amp) {
```

并删除文件顶部不再需要的 record 包 import(第 7 行 `import 'package:record/record.dart';`)——确认 `record` 仍被 `Amplitude`/`AudioEncoder` 等类型引用:`Amplitude` 类型用于 `_recSub` 声明(第 93 行 `StreamSubscription<Amplitude>`),故保留 import。

- [ ] **Step 3: 静态分析**

Run: `flutter analyze lib/services/audio_service.dart lib/screens/chat_screen.dart`
Expected: 0 error。

- [ ] **Step 4: 提交**

```bash
git add lib/services/audio_service.dart lib/screens/chat_screen.dart
git commit -m "fix(audio): 录音振幅复用内部 recorder,消除每次录音的 AudioRecorder 泄漏"
```

---

## 阶段 C:UI 打磨

> 以下多个修改集中在 `lib/screens/chat_screen.dart`。为减小冲突与回滚粒度,按子项分任务提交;每步都给出精确 old→new。

### Task C1: 聊天背景(极淡层次)

**Files:**
- Modify: `lib/screens/chat_screen.dart`(body: `Stack` / `CustomScrollView` 容器)

- [ ] **Step 1: 调整 Scaffold 背景与列表底层**

将 build 中 `return Scaffold(` 的 `backgroundColor`(第 184 行):

```dart
      backgroundColor: isDark ? const Color(0xFF0F0F0F) : const Color(0xFFFFFFFF),
```

替换为(仍为底色,后续在其上叠极淡渐变):

```dart
      backgroundColor: isDark ? const Color(0xFF0F0F0F) : const Color(0xFFFAFAFB),
```

在 `Stack(children: [` 之后、`NotificationListener<ScrollMetricsNotification>(` 之前(第 194-195 行之间)插入一个底层背景盒(放最底,不影响命中):

```dart
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: isDark
                            ? [const Color(0xFF151518), const Color(0xFF0B0B0D)]
                            : [const Color(0xFFFBFBFD), const Color(0xFFF3F4F8)],
                      ),
                    ),
                  ),
                ),
              ),
```

- [ ] **Step 2: 静态分析**

Run: `flutter analyze lib/screens/chat_screen.dart`
Expected: 0 error。

- [ ] **Step 3: 提交**

```bash
git add lib/screens/chat_screen.dart
git commit -m "style(chat): 极淡主题渐变背景,提升聊天区层次"
```

---

### Task C2: 统一强调色(顶栏蓝→紫)

**Files:**
- Modify: `lib/screens/chat_screen.dart`(`_Bar`)

- [ ] **Step 1: 顶栏 accent 改紫**

`_Bar.build` 中(第 1248 行):

```dart
    final accent = const Color(0xFF007AFF);
```

改为:

```dart
    const accent = Color(0xFF5B4BD6);
```

> 顶栏喇叭图标(第 1268 行)、打字动画 `_TypingDots(color: accent)`(第 1259 行)随之由蓝转紫,与气泡/输入栏统一。语义色(在线绿、错误红)保留。

- [ ] **Step 2: 静态分析**

Run: `flutter analyze lib/screens/chat_screen.dart`
Expected: 0 error。

- [ ] **Step 3: 提交**

```bash
git add lib/screens/chat_screen.dart
git commit -m "style(appbar): 顶栏强调色统一为紫,与气泡/输入栏一致"
```

---

### Task C3: 顶栏喇叭图标对比度(tint 底)

**Files:**
- Modify: `lib/screens/chat_screen.dart`(`_Bar` actions,第 1266-1272 行)

- [ ] **Step 1: 喇叭按钮套 tint 色块**

将 `_Bar` actions 中喇叭 IconButton(第 1266-1272 行):

```dart
        IconButton(
          icon: Icon(autoPlay ? Icons.volume_up_rounded : Icons.volume_off_rounded,
              size: 22, color: autoPlay ? accent : txt),
          tooltip: autoPlay ? '自动播放:开' : '自动播放:关',
          onPressed: onToggleAutoPlay,
        ),
```

替换为(激活态实心 accent+白图标;关态 tint 底+紫图标):

```dart
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggleAutoPlay,
            child: Tooltip(
              message: autoPlay ? '自动播放:开' : '自动播放:关',
              child: Container(
                width: 36, height: 36, alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: autoPlay ? accent : accent.withValues(alpha: isDark ? 0.22 : 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  autoPlay ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                  size: 20,
                  color: autoPlay ? Colors.white : accent,
                ),
              ),
            ),
          ),
        ),
```

- [ ] **Step 2: 静态分析**

Run: `flutter analyze lib/screens/chat_screen.dart`
Expected: 0 error。

- [ ] **Step 3: 提交**

```bash
git add lib/screens/chat_screen.dart
git commit -m "style(appbar): 喇叭开关套 tint 色块,浅/暗模式对比度充足"
```

---

### Task C4: 录音浮层减繁

**Files:**
- Modify: `lib/screens/chat_screen.dart`(`_VoiceOverlay`,第 559-572 行)

- [ ] **Step 1: 18 根条 → 5 根更粗、循环放慢**

`_VoiceOverlayState` 的 `AnimationController` duration(第 517 行):

```dart
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();
```

改为:

```dart
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
```

将波形 `List.generate(18, ...)`(第 561 行)整段:

```dart
                children: List.generate(18, (i) {
                  final phase = t * 2 * pi + i * 0.55;
                  final wave = 0.5 + 0.5 * sin(phase); // 0..1
                  final h = (5 + wave * 23 * amp).clamp(3.0, 28.0);
                  return Padding(padding: const EdgeInsets.symmetric(horizontal: 1.7),
                    child: Container(width: 3, height: h,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter,
                          colors: [accent.withValues(alpha: 0.5), accent]),
                        borderRadius: BorderRadius.circular(2))));
                }),
```

替换为(5 根更粗、相位错开更柔和):

```dart
                children: List.generate(5, (i) {
                  final phase = t * 2 * pi + i * 0.6;
                  final wave = 0.5 + 0.5 * sin(phase); // 0..1
                  final h = (8 + wave * 20 * amp).clamp(6.0, 28.0);
                  return Padding(padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Container(width: 5, height: h,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter,
                          colors: [accent.withValues(alpha: 0.5), accent]),
                        borderRadius: BorderRadius.circular(3))));
                }),
```

- [ ] **Step 2: 静态分析**

Run: `flutter analyze lib/screens/chat_screen.dart`
Expected: 0 error。

- [ ] **Step 3: 提交**

```bash
git add lib/screens/chat_screen.dart
git commit -m "style(voice): 录音浮层波形由 18 根简化为 5 根、循环放慢"
```

---

### Task C5: Markdown 缓存换 LRU

**Files:**
- Modify: `lib/screens/chat_screen.dart`(`_MarkdownContentState`,第 1136-1178 行)

- [ ] **Step 1: 顶部 import LRU**

在 `chat_screen.dart` import 区加(放任意位置):

```dart
import '../util/lru_cache.dart';
```

- [ ] **Step 2: 静态 Map 换 LruCache**

`_MarkdownContentState` 第 1136 行:

```dart
  static final Map<String, Widget> _cache = {};
```

改为:

```dart
  static final LruCache<String, Widget> _cache = LruCache(maxSize: 32);
```

- [ ] **Step 3: containsKey/[] 访问保持(经 LruCache 的 operator[]访问序)**

`_build()` 中(第 1147-1148 行)对缓存的使用:

```dart
    if (_cache.containsKey(key)) { _built = _cache[key]; return; }
```

`containsKey` 不触发访问序移位;读取需走 `[]` 才能更新 LRU 顺序。改为:

```dart
    final cached = _cache[key];
    if (cached != null) { _built = cached; return; }
```

写入处(第 1175 行)`_cache[key] = w;` 保持不变(LruCache 的 `[]=` 淘汰最久未用)。

- [ ] **Step 4: 静态分析 + 单测回归**

Run: `flutter analyze lib/screens/chat_screen.dart && flutter test`
Expected: 0 error,测试通过。

- [ ] **Step 5: 提交**

```bash
git add lib/screens/chat_screen.dart
git commit -m "perf(markdown): 渲染缓存换为有上限 LRU(32),防长会话内存膨胀"
```

---

### Task C6: 流式渲染隔离(流式期间只重建尾部气泡)

**Files:**
- Modify: `lib/screens/chat_screen.dart`(`ref.listen`、`_Streaming`、`_item`)

> 目标:流式 chunk 不再触发整张 SliverList 重建,只有尾部流式气泡经 Consumer 单独重建。

- [ ] **Step 1: ChatScreenState 增 streamingActive 标志**

在字段区(第 73 行 `bool _noMoreHistory = false;` 附近)加:

```dart
  // 流式输出"在场"标志:仅当 streamingText 在 null↔非null 之间翻转时才
  // 重建整树(增删尾部流式 sliver 项);流式内容逐字变化只由尾部 Consumer
  // 订阅 select((s)=>s.streamingText) 单独重建,不重建历史列表。
  bool _streamingActive = false;
```

- [ ] **Step 2: ref.listen 不再因流式内容变化 setState**

把 build 内 `ref.listen(chatProvider, (_, n) {...})`(第 141-174 行)整体替换为:

```dart
    ref.listen(chatProvider, (_, n) {
      final streamingToggled = (n.streamingText != null) != _streamingActive;
      final needsRebuild = n.messages.length != _lastLen ||
          n.toolCalls.length != _lastTC ||
          n.toolResults.length != _lastTR ||
          n.connectionState != _lastConn ||
          n.errorMessage != _state.errorMessage ||
          n.autoPlayVoice != _state.autoPlayVoice ||
          streamingToggled ||
          !identical(n.messages, _lastMessages);
      // 流式内容本身的逐字变化(n.streamingText)不走 setState,交给尾部
      // Consumer 自行重建;此处只更新本地缓存以供 _item 等读取。
      _streamingActive = n.streamingText != null;
      if (n.messages.length != _lastLen) _lastLen = n.messages.length;
      _lastTC = n.toolCalls.length; _lastTR = n.toolResults.length;
      _lastConn = n.connectionState; _lastMessages = n.messages;
      if (n.messages.length < _lastLen) _noMoreHistory = false;
      if (!needsRebuild) { _state = n; return; }

      final wasAtBottom = _atBottom;
      final isFirst = _firstLoad && n.messages.isNotEmpty;
      final grew = n.messages.length > _lastLen - 0 && (n.messages.length != _lastLen);
      final historyLoad = _loadingHistory && grew;
      _state = n;
      setState(() {});
      if (historyLoad) {
        _loadingHistory = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scrollCtrl.hasClients) return;
          final maxExtent = _scrollCtrl.position.maxScrollExtent;
          final target = (_preLoadPixels + (maxExtent - _preLoadMaxExtent))
              .clamp(0.0, maxExtent);
          _scrollCtrl.jumpTo(target);
        });
      } else if (isFirst || grew || (wasAtBottom && n.streamingText != null)) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd(jump: isFirst || grew));
      }
    });
```

> 关键:删除原先对 `n.streamingText != _lastStream` 的判断;逐字流式不再 setState 全树。`grew` 由 messages 长度变化判定。`_lastStream` 字段可保留但不再驱动重建;为避免未用告警,删除其声明(第 57 行 `String? _lastStream;`)及 `_initSync` 中对它的赋值(第 138 行 `; _lastStream = s.streamingText;` 片段)。`_initSync` 块(第 134-140 行)内删除 `_lastStream = s.streamingText;` 这一段。

- [ ] **Step 3: 尾部流式项改为 Consumer 订阅 streamingText**

`_item()`(第 369-391 行)末尾返回的流式项:

```dart
    return _Streaming(text: _state.streamingText!, bw: _w - 48, isDark: _isDark);
```

替换为只订阅 streamingText 的 Consumer:

```dart
    return Consumer(builder: (ctx, ref, _) {
      final st = ref.watch(chatProvider.select((s) => s.streamingText)) ?? '';
      return _Streaming(text: st, bw: _w - 48, isDark: _isDark);
    });
```

- [ ] **Step 4: 静态分析 + 单测回归**

Run: `flutter analyze lib/screens/chat_screen.dart && flutter test`
Expected: 0 error。

- [ ] **Step 5: 手动验证(构建后在设备确认)**

构建 release:`flutter build apk --release --target-platform android-arm64`(见阶段 D)。在长历史会话里发起长文本回复,确认流式逐字输出流畅、历史气泡无重绘闪烁。

- [ ] **Step 6: 提交**

```bash
git add lib/screens/chat_screen.dart
git commit -m "perf(streaming): 流式 chunk 只重建尾部气泡(Consumer select),不再重建整张列表"
```

---

### Task C7: 失败媒体气泡可重发

**Files:**
- Modify: `lib/providers/chat_provider.dart`(重发方法)、`lib/screens/chat_screen.dart`(失败态点击)

- [ ] **Step 1: provider 加 retryMediaSend**

在 `ChatNotifier` 内 `failMediaUpload`(第 382 行)之后加:

```dart
  /// 重发失败的媒体消息(用户在失败气泡上点击重试)。复用其 localPath
  /// 重新走上传→finalize 流程。仅对保留了 localPath 的失败消息有效。
  Future<void> retryMediaSend(int createdAt, String msgType, String? localPath, String? content) async {
    if (localPath == null || localPath.isEmpty) return;
    final file = File(localPath);
    if (!await file.exists()) {
      // 源文件已不在:标记错误,无法重发。
      return;
    }
    // 复位为上传中态,供 UI 显示进度。
    updateUploadProgress(createdAt, 0.0);
    final msgs = [...state.messages];
    for (int i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i].createdAt == createdAt && msgs[i].isFromMe) {
        msgs[i] = msgs[i].copyWith(status: MessageStatus.uploading, uploadProgress: 0.0);
        state = state.copyWith(messages: msgs);
        break;
      }
    }
    final mime = (msgType == 'voice') ? 'audio/wav'
        : (msgType == 'image') ? 'image/jpeg'
        : (content != null && content.contains('.pdf')) ? 'application/pdf'
        : 'application/octet-stream';
    final config = _config;
    final fs = FileService(serverUrl: config.serverUrl, apiKey: config.apiKey);
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
```

并在 `chat_provider.dart` 顶部 import 区补:

```dart
import 'dart:io';
```

- [ ] **Step 2: 失败气泡点击触发重发**

`_VoiceBubble`(第 937 行 `if (m.status == MessageStatus.uploading)` 分支)与普通态之间,新增失败态分支。在 `_VoiceBubbleState.build` 内,`if (m.status == MessageStatus.uploading)` 块之后插入:

```dart
    if (m.status == MessageStatus.error) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => ref.read(chatProvider.notifier).retryMediaSend(
            m.createdAt, m.msgType, m.localPath, m.content),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 30, height: 30, alignment: Alignment.center,
            decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.refresh_rounded, color: Colors.redAccent, size: 18)),
          const SizedBox(width: 10),
          Text('发送失败,点击重试', style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w500)),
        ]),
      );
    }
```

`_ImageBubble` 的 `_downloaded==null` 且非 uploading/loading 分支(第 896 行 `: const Icon(Icons.image...)`),改为仅在 `status != error` 时显示占位,error 时显示重试。将第 890-897 行:

```dart
    return SizedBox(
      width: w, height: w * 0.6,
      child: uploading
          ? Center(child: _UploadBadge(progress: prog))
          : (_loading
              ? const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)))
              : const Icon(Icons.image, size: 48, color: Colors.white54)),
    );
```

替换为:

```dart
    final errored = (widget.m.status as MessageStatus?) == MessageStatus.error;
    return SizedBox(
      width: w, height: w * 0.6,
      child: errored
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => ref.read(chatProvider.notifier)
                  .retryMediaSend(widget.m.createdAt as int, 'image',
                      widget.m.localPath as String?, widget.m.content as String?),
              child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.refresh_rounded, color: Colors.redAccent, size: 30),
                const SizedBox(height: 6),
                Text('发送失败,点击重试', style: TextStyle(color: Colors.redAccent.shade100, fontSize: 12)),
              ])))
          : (uploading
              ? Center(child: _UploadBadge(progress: prog))
              : (_loading
                  ? const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)))
                  : const Icon(Icons.image, size: 48, color: Colors.white54))),
    );
```

`_FileBubble` 的非上传态(第 1108 行 `if (!uploading)` 的 chevron)前,加失败态点击:在 `_FileBubbleState.build` 内 `final uploading = ...` 之后判断 `final errored = (widget.m.status as MessageStatus?) == MessageStatus.error;`,并把 `GestureDetector` 的 `onTap: uploading ? null : _open`(第 1085 行)改为 `onTap: uploading ? null : (errored ? _retry : _open)`,并在类内新增:

```dart
  void _retry() {
    ref.read(chatProvider.notifier).retryMediaSend(
        (widget.m.createdAt as int), (widget.m.msgType as String),
        (widget.m.localPath as String?), (widget.m.content as String?));
  }
```

并把占位文案 `_downloading ? '准备中…' : '点击打开'`(第 1105 行)改为 `_downloading ? '准备中…' : (errored ? '发送失败,点击重试' : '点击打开')`,颜色失败时用 `Colors.redAccent`。

- [ ] **Step 3: 静态分析**

Run: `flutter analyze lib/providers/chat_provider.dart lib/screens/chat_screen.dart`
Expected: 0 error。

- [ ] **Step 4: 提交**

```bash
git add lib/providers/chat_provider.dart lib/screens/chat_screen.dart
git commit -m "feat(media): 失败的语音/图片/文件气泡支持点击重发"
```

---

### Task C8: 顶栏 reconnecting 文案

**Files:**
- Modify: `lib/screens/chat_screen.dart`(`_Bar` 调用处与构造)

- [ ] **Step 1: _Bar 增 reconnecting 入参**

`_Bar` 类字段(第 1237-1239 行)加:

```dart
  final bool reconnecting;
```

构造函数参数(第 1240-1243 行 `const _Bar({...})`)内加 `this.reconnecting = false,`。

`statusText` / `statusColor`(第 1249-1250 行)改为:

```dart
    final statusText = conn
        ? '在线'
        : (reconnecting ? '重连中…' : (error ?? '未连接'));
    final statusColor = conn
        ? const Color(0xFF34C759)
        : (reconnecting ? const Color(0xFFFF9500) : const Color(0xFFFF6B6B));
```

- [ ] **Step 2: 调用处传入 reconnecting**

build 中 `_Bar(...)`(第 185-190 行)追加参数:

```dart
      appBar: _Bar(
        conn: conn, isDark: isDark, error: _state.errorMessage,
        streaming: _state.streamingText?.isNotEmpty == true,
        reconnecting: _state.connectionState == ConnState.reconnecting,
        autoPlay: _state.autoPlayVoice,
        onToggleAutoPlay: () => ref.read(chatProvider.notifier).setAutoPlayVoice(!_state.autoPlayVoice),
      ),
```

- [ ] **Step 3: 静态分析**

Run: `flutter analyze lib/screens/chat_screen.dart`
Expected: 0 error。

- [ ] **Step 4: 提交**

```bash
git add lib/screens/chat_screen.dart
git commit -m "feat(appbar): 重连中显示"重连中…"(橙),区别于"未连接"(红)"
```

---

## 阶段 D:集成构建与验证

### Task D1: 全量静态分析与单测

- [ ] **Step 1: analyze 全项目**

Run: `flutter analyze`
Expected: 0 error(可有少量 info/warning,逐条确认无回归)。

- [ ] **Step 2: 全量单测**

Run: `flutter test`
Expected: 全部通过(含 reconnect/retry/lifecycle/lru/play_queue/config/message)。

- [ ] **Step 3: 如失败,定位并修复后再跑;通过后提交(若有修复)**

```bash
git add -A && git commit -m "fix: 集成验证修复" || echo "无需提交"
```

### Task D2: 构建 release APK

- [ ] **Step 1: 构建**

Run: `flutter build apk --release --target-platform android-arm64`
Expected: `✓ Built build/app/outputs/flutter-apk/app-release.apk`。

- [ ] **Step 2: 安装到设备**

Run: `adb install -r build/app/outputs/flutter-apk/app-release.apk`
Expected: `Success`。

> 设备(华为 PGT-AN10)经无线 ADB 已连接;若未连接,用 `adb connect <ip>:<port>` 后重试。

---

## 自审(对照规格)

- **S1 SSE 自重连** → Task B2。✅
- **S2 去空消息/只读探测** → Task B2 Step3。✅
- **S3 生命周期观察** → Task B5(策略 A3 + provider 接线)。✅
- **S4 上传/下载重试** → Task B4。✅
- **S5 空闲看门狗** → Task B2 Step6。✅
- **S6 reconnecting 文案** → Task B1(枚举)+ B2/B3(置位)+ C8(UI)。✅
- **E 流式渲染隔离** → Task C6。✅
- **A Markdown LRU** → Task A4 + C5。✅
- **C cleanOldCache 调用** → Task B5 Step5。✅
- **Q 录音器泄漏** → Task B6。✅
- **U1 背景层次** → C1。✅
- **U2 统一强调色** → C2。✅
- **U3 图标对比度** → C3。✅
- **U4 录音浮层减繁** → C4。✅
- **U5 失败重发** → C7。✅

类型一致性:`reconnectDelayMs`/`ReconnectAttempt`(A1,B2);`isTransientDioError`/`withRetry`(A2,B4);`shouldReconnectOnResume`(A3,B5);`LruCache`(A4,C5)——签名前后一致。`ConnState.reconnecting`(B1)被 B2/B3/C8 一致使用。
