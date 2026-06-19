# 出站消息与生成兜底(稳定性第二轮) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让单条文本消息在弱网/死 socket 下不再静默丢失,生成中途断网的半截回复落盘标注,并如实说明 SSE 模式的后台推送限制。

**Architecture:** 第一轮已解决「连接保活」;本轮在连接之上加「单条消息/单次生成」可靠性:出站消息加 `error` 态+点击重发(复用媒体已有 UX);SSE 首字节前重试;WS 死 socket 发送入队重发;断网半截回复落盘。可测逻辑抽成纯函数(`isTransientHttpError`、`interruptedBotText`、`markOutboundError`),ChatNotifier 接线层用 analyze+构建验证(本仓库无 mock seam,历史纯逻辑测试)。

**Tech Stack:** Flutter 3.38.x,Dart ≥3.2,Riverpod 2.5(StateNotifier),http ^1.2,web_socket_channel,flutter_test(纯逻辑单测)。

**关键约束:**
- workspace `.gitignore` 忽略 `test` → 测试文件需 `git add -f`(见 memory)。
- 包名 `top.zztweb.astrbot`,arm64-only release 构建,无线 ADB 设备(见 memory)。
- 不重写 WS/SSE 客户端;不引入服务端不支持的能力。

---

## 文件结构

| 文件 | 职责 |
|------|------|
| `lib/util/retry.dart` | 新增 `isTransientHttpError(Object)` 纯函数(http 包等价的瞬态判定,供 SSE 用) |
| `lib/services/astrbot_sse_client.dart` | `_sendHttpMessage` 首字节前重试(用 `withRetry`+`isTransientHttpError`);`sendMessage` 改返回 `bool`(SSE 恒 `true`,乐观) |
| `lib/services/astrbot_ws_client.dart` | `sendMessage` 改返回 `bool`(透传 `_sendRaw` 结果);死 socket 仍 `_forceReconnect()` 治连接,但向上层暴露失败 |
| `lib/providers/chat_provider.dart` | `sendText` 失败→`error`;SSE 在途跟踪 `_inflightTextCreatedAt`;新增 `retryTextSend`;G4 半截回复兜底;WS 死 socket 发送保持 pending+入队。新增纯函数 `interruptedBotText` / `markOutboundError`(独立到 `util/outbound.dart`) |
| `lib/util/outbound.dart`(新) | 纯函数 `interruptedBotText(String?)`、`markOutboundError(List,int)`、`setMessagePending(List,int)` —— 出站状态变换,可单测 |
| `lib/screens/chat_screen.dart` | 文本气泡 `error` 态渲染点击重发(复用 `retryTextSend`);设置页连接模式补 SSE 限制说明 |
| `test/outbound_test.dart`(新) | 纯函数单测 |
| `test/retry_test.dart` | 追加 `isTransientHttpError` 单测 |

---

## Task 1: `isTransientHttpError` 纯函数 + 单测

**Files:**
- Modify: `lib/util/retry.dart`(末尾追加)
- Modify: `test/retry_test.dart`(追加 group)

- [ ] **Step 1: 写失败测试**

在 `test/retry_test.dart` 的 `void main()` 内追加(放在现有 group 之后、`}` 之前):

```dart
  group('isTransientHttpError', () {
    test('SocketException / TimeoutException 视为瞬态', () {
      expect(isTransientHttpError(SocketException('reset by peer')), isTrue);
      expect(isTransientHttpError(TimeoutException('timed out')), isTrue);
    });
    test('连接级 http ClientException 视为瞬态', () {
      expect(
          isTransientHttpError(
              http.ClientException('Failed host lookup')),
          isTrue);
    });
    test('普通异常不重试', () {
      expect(isTransientHttpError(StateError('boom')), isFalse);
      expect(isTransientHttpError(FormatException('bad')), isFalse);
    });
  });
```

并在文件顶部 import 区追加:

```dart
import 'dart:async';
import 'dart:io' show SocketException;
import 'package:http/http.dart' as http;
import 'package:astrbot_app/util/retry.dart';
```

- [ ] **Step 2: 跑测试确认失败**

Run: `/home/zzt/flutter/bin/flutter test test/retry_test.dart`
Expected: FAIL —— `isTransientHttpError` 未定义 / `http` 未引入。

- [ ] **Step 3: 实现 `isTransientHttpError`**

在 `lib/util/retry.dart` 末尾追加(顶部追加 `import 'dart:async';` 与 `import 'dart:io' show SocketException;` 与 `import 'package:http/http.dart' as http;`):

```dart
/// http 包等价的瞬态错误判定(供 SSE 首字节前重试用)。
/// 与 [isTransientDioError] 对齐:连接超时、socket 重置、连接级 http 异常视为瞬态;
/// 其余(含 4xx body 异常的语义)默认不重试。
bool isTransientHttpError(Object e) {
  if (e is SocketException) return true;            // 连接重置/拒绝/断网
  if (e is TimeoutException) return true;          // .timeout() 触发
  if (e is http.ClientException) {
    // ClientException 在连接失败时 message 通常含 "Failed"/"Connection";
    // 它也可能包装非瞬态错误,但 http 包无更细 type,保守按瞬态处理
    // (首字节前重试最多 3 次,代价可控)。
    return true;
  }
  return false;
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `/home/zzt/flutter/bin/flutter test test/retry_test.dart`
Expected: PASS(全部 group 绿)。

- [ ] **Step 5: 提交**

```bash
cd /home/zzt/workspace/astrbot-app
git add lib/util/retry.dart
git add -f test/retry_test.dart
git commit -m "feat(retry): isTransientHttpError — http 包瞬态判定(供 SSE 重试)"
```

---

## Task 2: SSE 首字节前重试

**Files:**
- Modify: `lib/services/astrbot_sse_client.dart:127-198`(`_sendHttpMessage`)
- Modify: `lib/services/astrbot_sse_client.dart:116-125`(`sendMessage` 返回 `bool`)

- [ ] **Step 1: 改 `sendMessage` 返回 `bool`**

把 `astrbot_sse_client.dart` 的 `sendMessage` 改为:

```dart
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
```

- [ ] **Step 2: `_sendHttpMessage` 首字节前重试**

把 `_sendHttpMessage` 内「建立请求 + 收到首字节」阶段包进 `withRetry`。替换从 `client = http.Client();` 到首个 SSE 行解析之前的连接/发送部分。**关键是:重试单元 = 「发请求 + 等到 `streamedResponse`」;一旦拿到 streamedResponse(首字节路径已通)就退出重试,后续流式解析不在重试内。**

新增 import(文件顶部):
```dart
import '../util/retry.dart';
```

把 `_sendHttpMessage` 的 body 构造之后、`_awaitingFirstByte = true;` 那段替换为:

```dart
      _awaitingFirstByte = true;
      // 首字节前重试:建立连接 / 等待响应头阶段若遇瞬态错误(连接重置/超时)
      // 则按指数退避重试,与 FileService 一致。一旦拿到 streamedResponse
      // 即视为请求已送达,后续流式解析不在重试范围内(中途断开由 G4 兜底)。
      final streamedResponse = await withRetry(
        () => client!.send(request).timeout(const Duration(seconds: 300)),
        isTransient: isTransientHttpError,
        maxAttempts: 3,
        delayFor: (i) => Duration(milliseconds: 1000 << i),
      );
```

(删除原来的单次 `await client.send(request).timeout(...)` 那一行。)

- [ ] **Step 3: 确认无类型/引用错误**

Run: `/home/zzt/flutter/bin/flutter analyze lib/services/astrbot_sse_client.dart`
Expected: 无 error(可能有 info,忽略)。

- [ ] **Step 4: 跑现有测试回归**

Run: `/home/zzt/flutter/bin/flutter test`
Expected: 全绿(本任务未加新测试,确保未破坏既有)。

- [ ] **Step 5: 提交**

```bash
cd /home/zzt/workspace/astrbot-app
git add lib/services/astrbot_sse_client.dart
git commit -m "feat(sse): 首字节前重试 — 弱网下瞬态失败不再丢单条文本"
```

---

## Task 3: WS `sendMessage` 返回 bool,死 socket 不静默丢消息

**Files:**
- Modify: `lib/services/astrbot_ws_client.dart:143-156`(`sendMessage`)

- [ ] **Step 1: 改 `sendMessage` 返回 `bool`,保留治愈逻辑**

把 `astrbot_ws_client.dart` 的 `sendMessage` 改为:

```dart
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
```

- [ ] **Step 2: 确认无错误**

Run: `/home/zzt/flutter/bin/flutter analyze lib/services/astrbot_ws_client.dart`
Expected: 无 error。

- [ ] **Step 3: 跑测试回归**

Run: `/home/zzt/flutter/bin/flutter test`
Expected: 全绿。

- [ ] **Step 4: 提交**

```bash
cd /home/zzt/workspace/astrbot-app
git add lib/services/astrbot_ws_client.dart
git commit -m "feat(ws): sendMessage 返回 bool — 死 socket 上发送不再静默丢消息"
```

---

## Task 4: 出站状态变换纯函数(`outbound.dart`)+ 单测

**Files:**
- Create: `lib/util/outbound.dart`
- Create: `test/outbound_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// test/outbound_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/models/message.dart';
import 'package:astrbot_app/util/outbound.dart';

LocalMessage _msg({required int createdAt, MessageStatus status = MessageStatus.sent, bool isFromMe = true, String content = 'hi'}) =>
    LocalMessage(msgType: 'text', content: content, isFromMe: isFromMe, status: status, createdAt: createdAt);

void main() {
  group('interruptedBotText', () {
    test('空/空白返回 null', () {
      expect(interruptedBotText(null), isNull);
      expect(interruptedBotText('   '), isNull);
      expect(interruptedBotText(''), isNull);
    });
    test('有内容追加中断后缀', () {
      expect(interruptedBotText('一半回复'),
          '一半回复\n\n_(回复中断,请重试)_');
    });
  });

  group('markOutboundError', () {
    test('把指定 createdAt 的我发出消息置 error', () {
      final msgs = [_msg(createdAt: 100), _msg(createdAt: 200)];
      final out = markOutboundError(msgs, 100);
      expect(out[0].status, MessageStatus.error);
      expect(out[1].status, MessageStatus.sent);   // 未误伤
    });
    test('不碰对方消息', () {
      final msgs = [_msg(createdAt: 100, isFromMe: false)];
      expect(markOutboundError(msgs, 100)[0].status, MessageStatus.sent);
    });
    test('找不到时不抛错(原样返回)', () {
      final msgs = [_msg(createdAt: 100)];
      expect(markOutboundError(msgs, 999).length, 1);
    });
  });

  group('setMessagePending', () {
    test('把指定消息回退为 pending', () {
      final msgs = [_msg(createdAt: 100, status: MessageStatus.error)];
      final out = setMessagePending(msgs, 100);
      expect(out[0].status, MessageStatus.pending);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `/home/zzt/flutter/bin/flutter test test/outbound_test.dart`
Expected: FAIL —— `outbound.dart` 不存在。

- [ ] **Step 3: 实现 `outbound.dart`**

```dart
// lib/util/outbound.dart
import '../models/message.dart';

/// 生成中途断网时,把已积累的流式文本落盘为一条「中断」消息的内容。
/// 空/纯空白返回 null(不落盘,避免空气泡)。
String? interruptedBotText(String? streaming) {
  if (streaming == null || streaming.trim().isEmpty) return null;
  return '$streaming\n\n_(回复中断,请重试)_';
}

/// 把指定 createdAt 的「我发出」消息标记为发送失败(error)。
/// 纯函数:返回新列表,不改原列表;不碰对方消息;找不到则原样返回。
List<LocalMessage> markOutboundError(List<LocalMessage> msgs, int createdAt) =>
    msgs.map((m) => (m.isFromMe && m.createdAt == createdAt)
        ? m.copyWith(status: MessageStatus.error)
        : m).toList();

/// 把指定 createdAt 的消息回退为 pending(重发前复位)。
List<LocalMessage> setMessagePending(List<LocalMessage> msgs, int createdAt) =>
    msgs.map((m) => (m.createdAt == createdAt)
        ? m.copyWith(status: MessageStatus.pending)
        : m).toList();
```

- [ ] **Step 4: 跑测试确认通过**

Run: `/home/zzt/flutter/bin/flutter test test/outbound_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
cd /home/zzt/workspace/astrbot-app
git add lib/util/outbound.dart
git add -f test/outbound_test.dart
git commit -m "feat(outbound): 出站状态变换纯函数(error/pending/中断文本)"
```

---

## Task 5: ChatNotifier 在途跟踪 + `sendText` 失败处理 + `retryTextSend`

**Files:**
- Modify: `lib/providers/chat_provider.dart`

- [ ] **Step 1: 顶部 import + 字段**

在 `chat_provider.dart` 顶部 import 区追加:
```dart
import '../util/outbound.dart';
```

在 `ChatNotifier` 字段区(`int _historyOffset = 0;` 附近)追加:
```dart
  /// SSE 在途跟踪:当前正在等服务端响应的「我发出」文本消息的 createdAt。
  /// 仅 SSE 模式用 —— SSE 发送是 fire-and-forget,真正的失败经 error 事件回传,
  /// 靠这个把失败关联回具体消息。收到该消息的首个流式事件/complete/end 即清空。
  int? _inflightTextCreatedAt;
```

- [ ] **Step 2: 重构 `sendText`,抽出 `_dispatchText`**

把现有 `sendText(String text)` 整体替换为下面两个方法。`_dispatchText` 同时服务于「新发」和「重发」,避免重复:

```dart
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
          // WS 同步确认送达 → 标 sent。
          state = state.copyWith(
            messages: state.messages
                .map((m) => m.createdAt == createdAt
                    ? m.copyWith(status: MessageStatus.sent) : m).toList(),
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
                  ? m.copyWith(status: MessageStatus.sent) : m).toList(),
        );
      }
    } else {
      _pendingQueue.add(msgParts);
      if (_client == null) {
        state = state.copyWith(errorMessage: '客户端未初始化');
      }
    }
  }
```

- [ ] **Step 3: 新增 `retryTextSend`**

在 `_dispatchText` 之后追加(与 `retryMediaSend` 对称):

```dart
  /// 重发失败的文本消息(用户在失败文本气泡上点击重试)。
  Future<void> retryTextSend(int createdAt) async {
    final idx = state.messages.indexWhere(
        (m) => m.createdAt == createdAt && m.isFromMe);
    if (idx < 0) return;
    final text = state.messages[idx].content;
    if (text == null || text.isEmpty) return;
    // 复位为 pending,供 UI 反馈。
    state = state.copyWith(messages: setMessagePending(state.messages, createdAt));
    final msgParts = <Map<String, dynamic>>[{'type': 'plain', 'text': text}];
    _dispatchText(createdAt: createdAt, text: text, msgParts: msgParts);
  }
```

- [ ] **Step 4: `error` 事件 → 关联在途文本翻 error + G4 半截回复**

修改 `_handleEvent` 的 `case 'error':` 分支,替换为:

```dart
      case 'error':
        // SSE 在途文本失败:把对应消息翻成 error(供点击重发)。
        if (!_usingWs && _inflightTextCreatedAt != null) {
          final inflight = _inflightTextCreatedAt;
          _inflightTextCreatedAt = null;
          final msgs = markOutboundError(state.messages, inflight);
          for (final m in msgs) {
            if (m.createdAt == inflight && m.isFromMe) _cache.upsert(m);
          }
          state = state.copyWith(messages: msgs);
        }
        state = state.copyWith(errorMessage: event.data ?? '未知错误');
        break;
```

- [ ] **Step 5: 清在途标记(complete/end/plain 已送达)**

在 `_handleEvent` 的 `case 'complete':` 和 `case 'end':` 两个分支体开头各加一行(在 `if (state.streamingText != null ...)` 之前):

```dart
        _inflightTextCreatedAt = null;
```

在 `case 'plain':` 分支开头加(首块到达=已开始回复,SSE 文本视为送达):

```dart
        if (!_usingWs) _inflightTextCreatedAt = null;
```

- [ ] **Step 6: 确认无错误 + 回归**

Run: `/home/zzt/flutter/bin/flutter analyze lib/providers/chat_provider.dart`
Expected: 无 error。

Run: `/home/zzt/flutter/bin/flutter test`
Expected: 全绿。

- [ ] **Step 7: 提交**

```bash
cd /home/zzt/workspace/astrbot-app
git add lib/providers/chat_provider.dart
git commit -m "feat(chat): 文本发送失败标记 error + 重发;SSE 在途跟踪关联失败"
```

---

## Task 6: G4 半截回复兜底(断网落盘)

**Files:**
- Modify: `lib/providers/chat_provider.dart`(连接状态监听 + 复用 `interruptedBotText`)

- [ ] **Step 1: 在连接状态监听里兜底半截回复**

在 `connect()` 内 `_client!.state.listen((s) {...})` 回调的**开头**追加(在现有 `final err = ...` 之前):

```dart
        // G4:流式进行中连接断开(complete/end 未到)→ 把已积累文本落盘标注中断,
        // 避免孤儿气泡/丢失。有 content 已落盘的情况不会触发(streamingText 已清空)。
        if (s == ConnState.disconnected || s == ConnState.reconnecting) {
          _flushInterruptedStream();
        }
```

- [ ] **Step 2: 实现 `_flushInterruptedStream`**

在 ChatNotifier 内(`_handleEvent` 附近)追加:

```dart
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
```

- [ ] **Step 3: 确认无错误 + 回归**

Run: `/home/zzt/flutter/bin/flutter analyze lib/providers/chat_provider.dart`
Expected: 无 error。

Run: `/home/zzt/flutter/bin/flutter test`
Expected: 全绿(`interruptedBotText` 已在 Task 4 覆盖)。

- [ ] **Step 4: 提交**

```bash
cd /home/zzt/workspace/astrbot-app
git add lib/providers/chat_provider.dart
git commit -m "feat(chat): 生成中途断网半截回复落盘标注中断"
```

---

## Task 7: 文本气泡 `error` 态点击重发 UI

**Files:**
- Modify: `lib/screens/chat_screen.dart`(文本气泡渲染处,搜索 `_TextBubble` 或文本消息渲染)

- [ ] **Step 1: 定位文本气泡渲染**

Run: `grep -n "msgType == 'text'\|_TextBubble\|class.*Bubble" lib/screens/chat_screen.dart`
找到文本消息的渲染 widget(通常按 `m.msgType == 'text'` 分支渲染 `Text(content)`)。

- [ ] **Step 2: 文本气泡 `error` 态渲染重发入口**

在该文本渲染的 build 里,在渲染正文 `Text` 之前插入对 `status == error` 的分支(复用媒体 errored 样式:refresh 图标 + 红字提示)。例如,若正文是:

```dart
return Container(/* ... 紫色气泡 ... */, child: Text(content));
```

改为:

```dart
    final errored = (widget.m.status as MessageStatus?) == MessageStatus.error;
    if (errored) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => ref.read(chatProvider.notifier)
            .retryTextSend(widget.m.createdAt as int),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline_rounded,
              color: Colors.redAccent, size: 18),
          const SizedBox(width: 6),
          Flexible(
            child: Text(content,
                style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: 13,
                    decoration: TextDecoration.lineThrough))),
          const Icon(Icons.refresh_rounded,
              color: Colors.redAccent, size: 16),
        ]),
      );
    }
    return Container(/* ... 原紫色气泡 ... */, child: Text(content));
```

> 实现者需按该 widget 实际变量名(如 `m`/`widget.m`、`fg`、`isMe`)调整。核心:命中 `MessageStatus.error` → 渲染可点击的失败态,`onTap` 调 `retryTextSend(createdAt)`。

- [ ] **Step 3: 确认无错误**

Run: `/home/zzt/flutter/bin/flutter analyze lib/screens/chat_screen.dart`
Expected: 无 error。

- [ ] **Step 4: 提交**

```bash
cd /home/zzt/workspace/astrbot-app
git add lib/screens/chat_screen.dart
git commit -m "feat(ui): 文本气泡失败态点击重发"
```

---

## Task 8: 设置页 SSE 后台推送限制说明

**Files:**
- Modify: `lib/screens/settings_screen.dart:113-132`(「连接模式」ListTile)

- [ ] **Step 1: 给「连接模式」加 SSE 限制说明**

把现有「连接模式」ListTile 的 `subtitle` 改为多行说明,在 `ListTile(...)` 内 `trailing` 之后增加说明文字。替换该 `ListTile(...)` 块为:

```dart
          ListTile(
            title: const Text('连接模式'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_config.connectionMode == 'sse'
                    ? 'SSE(默认,更稳定)'
                    : 'WebSocket'),
                const SizedBox(height: 2),
                const Text(
                  'SSE 仅在请求-响应期间收发;需要后台实时接收 bot 推送请用 WebSocket',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
            trailing: DropdownButton<String>(
              value: _config.connectionMode,
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 'sse', child: Text('SSE(推荐)')),
                DropdownMenuItem(value: 'ws', child: Text('WebSocket')),
              ],
              onChanged: (v) async {
                if (v != null) {
                  await _config.setConnectionMode(v);
                  setState(() {});
                  ref.read(chatProvider.notifier).connect();
                }
              },
            ),
          ),
```

- [ ] **Step 2: 确认无错误**

Run: `/home/zzt/flutter/bin/flutter analyze lib/screens/settings_screen.dart`
Expected: 无 error。

- [ ] **Step 3: 提交**

```bash
cd /home/zzt/workspace/astrbot-app
git add lib/screens/settings_screen.dart
git commit -m "docs(ui): 连接模式说明 SSE 后台推送限制"
```

---

## Task 9: 全量验证 + 版本号 + 构建

**Files:**
- Modify: `android/app/build.gradle.kts:34-35`

- [ ] **Step 1: 全量 analyze**

Run: `/home/zzt/flutter/bin/flutter analyze`
Expected: 无 error。

- [ ] **Step 2: 全量测试**

Run: `/home/zzt/flutter/bin/flutter test`
Expected: 全绿。

- [ ] **Step 3: 版本号 1.1.3 → 1.1.4**

`android/app/build.gradle.kts` 中:
```kotlin
        versionCode = 6
        versionName = "1.1.4"
```

- [ ] **Step 4: 构建 release APK(arm64)**

Run:
```bash
cd /home/zzt/workspace/astrbot-app
/home/zzt/flutter/bin/flutter build apk --release --target-platform android-arm64
```
Expected: `✓ Built build/app/outputs/flutter-apk/app-release.apk`。

- [ ] **Step 5: 安装到无线 ADB 设备并确认启动**

Run:
```bash
adb devices   # 确认有设备
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell am start -n top.zztweb.astrbot/.MainActivity
sleep 3
adb shell pidof top.zztweb.astrbot  # 期望输出进程号(非空=启动存活)
```
Expected: 安装成功 + 进程存活。

- [ ] **Step 6: 提交版本号**

```bash
cd /home/zzt/workspace/astrbot-app
git add android/app/build.gradle.kts
git commit -m "chore: bump version 1.1.3 -> 1.1.4"
```

---

## 自检(spec 覆盖)

对照 `docs/superpowers/specs/2026-06-19-outbound-reliability-design.md`:
- **G1 文本发送零重试**:Task 2(SSE 首字节前重试)+ Task 5(error 态+retryTextSend)✅
- **G2 WS 死 socket 丢消息**:Task 3(返回 bool)+ Task 5(死 socket 入队)✅
- **G3 SSE 后台推送限制**:Task 8(设置页说明,文档化)✅
- **G4 半截回复孤儿**:Task 4(`interruptedBotText`)+ Task 6(`_flushInterruptedStream`)✅
- 测试:Task 1/4 纯函数单测;Task 2/3/5/6/7/8 接线层 analyze+构建+回归 ✅
- 验收标准(spec §6):Task 9 全量验证 ✅
