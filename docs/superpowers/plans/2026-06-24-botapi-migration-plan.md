# BotAPI 迁移实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 AstrBot Android 客户端从 webchat 接口整体迁移到 `astrbot_plugin_botapi` 的 REST+SSE API，把「多会话」改为「多账户」（每账户 = 一个 botapi token），并精简设置页（删除昵称/API Key/Config ID/连接模式）。

**Architecture:** 账户级凭据（serverUrl + token）存于 AccountStore（SharedPreferences）。ChatNotifier 为活跃账户维持一个 BotApiClient（SSE /stream）收回复，经 BotApiHttp（REST）发消息/上传/拉历史。CacheService（sqflite v6）按 account_id 分区、用 server_id 去重 botapi 历史行。断连重连先 fetchHistory 合并补漏再续接 SSE。

**Tech Stack:** Flutter 3.38 / Dart ≥3.2 / Riverpod 2.5 / http / dio / sqflite / shared_preferences / connectivity_plus / flutter_foreground_task。无新增依赖。

**Spec:** `docs/superpowers/specs/2026-06-24-botapi-migration-design.md`

**约定（跨任务一致的类型/签名）：**
- `Account { id, label?, serverUrl, token, createdAt, lastUsedAt, displayName }`
- `AccountStore`：`load() / add({serverUrl, token, label}) → Account / select(id)→bool / rename(id,label)→bool / updateCredentials(id,{serverUrl,token})→bool / delete(id, deleteMessages)→String / touchCurrent(nowMs) / currentId / accounts`，`kMaxAccounts=25`
- `ConnState` 枚举定义于 `lib/models/botapi_event.dart`
- `BotApiEvent`：见 Task 1
- `HistoryRow` 定义于 `lib/models/history_row.dart`，被 `botapi_http` 与 `cache_service` 共用
- `BotApiHttp(serverUrl, token)`：`auth()→Future<bool>` / `sendMessage({text, fileIds})→Future<String?>` / `uploadFile(File, mime, onProgress)→Future<UploadResult?>` / `fetchHistory({since, before, limit})→Future<HistoryResult>` / `downloadByUrl(url)→Future<File?>`，顶层 `String botapiBase(String serverUrl)`
- `BotApiClient(serverUrl, token)`：`connect({int? sinceCursor})` / `Stream<BotApiEvent> events` / `Stream<ConnState> state` / `dispose()`
- CacheService 形参统一 `accountId`（DB 列名仍为 `session_id`，语义=账户 id）

---

## File Structure

**Create:**
- `lib/models/botapi_event.dart` — SSE 事件模型 + ConnState
- `lib/models/account.dart` — 账户数据类
- `lib/models/history_row.dart` — 历史行纯数据（http 与 cache 共用）
- `lib/services/account_store.dart` — 账户注册表纯逻辑（+ PrefsAccountStorage）
- `lib/services/botapi_http.dart` — 无状态 REST（auth/message/upload/history/download）
- `lib/services/botapi_client.dart` — SSE 流客户端 + 重连
- `lib/widgets/account_drawer.dart` — 账户选择抽屉
- `lib/screens/account_editor_screen.dart` — 添加/编辑账户表单
- `test/botapi_event_test.dart`
- `test/account_store_test.dart`
- `test/botapi_http_base_test.dart`
- `test/cache_service_history_test.dart`

**Modify:**
- `lib/services/cache_service.dart` — DB v6：server_id 列 + mergeHistory
- `lib/models/message.dart` — 增 serverId
- `lib/services/config_service.dart` — 删 webchat 字段 + v3 迁移
- `lib/providers/chat_provider.dart` — 重写（账户/botapi/事件）
- `lib/providers/config_provider.dart` — isConfigured 语义
- `lib/screens/setup_screen.dart` — 添加首个账户
- `lib/screens/settings_screen.dart` — 精简
- `lib/screens/chat_screen.dart` — 抽屉/标题/媒体/思考
- `lib/main.dart` — 启动清理
- `android/app/build.gradle.kts` — 1.2.0 / versionCode 12

**Delete:**
- `lib/services/astrbot_sse_client.dart`
- `lib/services/astrbot_ws_client.dart`
- `lib/models/chat_session.dart`
- `lib/services/session_store.dart`
- `lib/services/prefs_storage.dart`
- `lib/widgets/session_drawer.dart`
- `lib/models/chat_event.dart`
- `test/session_store_test.dart`（被 account_store_test 替代）

---

## Task 1: BotApiEvent 模型 + ConnState

**Files:**
- Create: `lib/models/botapi_event.dart`
- Test: `test/botapi_event_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// test/botapi_event_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/models/botapi_event.dart';

void main() {
  group('BotApiEvent.fromSse', () {
    test('message text streaming', () {
      final e = BotApiEvent.fromSse('message', {
        'message_id': 'botapi_abc', 'type': 'text', 'content': '你好',
        'streaming': true, 'timestamp': 1719234567,
      });
      expect(e.event, 'message');
      expect(e.type, 'text');
      expect(e.content, '你好');
      expect(e.streaming, true);
      expect(e.isFinal, isNull);
      expect(e.messageId, 'botapi_abc');
    });
    test('message text final 自纠正', () {
      final e = BotApiEvent.fromSse('message', {
        'message_id': 'botapi_abc', 'type': 'text', 'content': '完整答案',
        'final': true,
      });
      expect(e.isFinal, true);
      expect(e.streaming, isNull);
    });
    test('message tool_status 不并入答案', () {
      final e = BotApiEvent.fromSse('message', {
        'type': 'text', 'subtype': 'tool_status', 'content': '🔨 调用工具',
      });
      expect(e.subtype, 'tool_status');
    });
    test('message file content 为对象', () {
      final e = BotApiEvent.fromSse('message', {
        'type': 'file', 'content': {'name': 'a.pdf', 'url': 'http://x/y'},
      });
      expect(e.type, 'file');
      expect(e.content, contains('a.pdf'));
    });
    test('thinking', () {
      final e = BotApiEvent.fromSse('thinking', {'content': '思考中', 'streaming': true});
      expect(e.event, 'thinking');
      expect(e.content, '思考中');
    });
    test('error SESSION_KICKED', () {
      final e = BotApiEvent.fromSse('error', {'code': 'SESSION_KICKED', 'message': '管理员已断开'});
      expect(e.code, 'SESSION_KICKED');
      expect(e.message, '管理员已断开');
    });
    test('ping 忽略但不抛', () {
      final e = BotApiEvent.fromSse('ping', {});
      expect(e.event, 'ping');
    });
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `flutter test test/botapi_event_test.dart`
Expected: FAIL（文件/类型不存在）

- [ ] **Step 3: 实现**

```dart
// lib/models/botapi_event.dart
import 'dart:convert';

enum ConnState { disconnected, connecting, reconnecting, connected }

class BotApiEvent {
  final String event; // message | thinking | error | ping
  final String? messageId;
  final String? type; // message: text|image|audio|file
  final String? subtype; // tool_status
  final String? content; // text:字符串；image/audio:URL；file:JSON 字符串
  final bool? streaming;
  final bool? isFinal;
  final bool? segmentEnd;
  final int? timestamp;
  final String? code; // error
  final String? message; // error
  final Map<String, dynamic>? raw;

  const BotApiEvent({
    required this.event,
    this.messageId,
    this.type,
    this.subtype,
    this.content,
    this.streaming,
    this.isFinal,
    this.segmentEnd,
    this.timestamp,
    this.code,
    this.message,
    this.raw,
  });

  /// 从 SSE 的 event 类型 + data JSON 构造。
  /// content 统一存为字符串：text/image/audio 取原串，file/对象取 jsonEncode。
  factory BotApiEvent.fromSse(String eventType, Map<String, dynamic> json) {
    final c = json['content'];
    String? contentStr;
    if (c is String) {
      contentStr = c;
    } else if (c != null) {
      contentStr = jsonEncode(c);
    }
    return BotApiEvent(
      event: eventType,
      messageId: json['message_id']?.toString(),
      type: json['type'] as String?,
      subtype: json['subtype'] as String?,
      content: contentStr,
      streaming: json['streaming'] as bool?,
      isFinal: json['final'] as bool?,
      segmentEnd: json['segment_end'] as bool?,
      timestamp: (json['timestamp'] as num?)?.toInt(),
      code: json['code'] as String?,
      message: json['message'] as String?,
      raw: json,
    );
  }

  bool get isPing => event == 'ping';
  bool get isError => event == 'error';
  bool get isThinking => event == 'thinking';
  bool get isMessage => event == 'message';
  bool get isToolStatus => subtype == 'tool_status';
  bool get isFinalText => isMessage && type == 'text' && isFinal == true;
  bool get isStreamingText => isMessage && type == 'text' && streaming == true;
  bool get isMedia => isMessage && (type == 'image' || type == 'audio' || type == 'file');
}
```

- [ ] **Step 4: 运行确认通过**

Run: `flutter test test/botapi_event_test.dart`
Expected: PASS（全部）

- [ ] **Step 5: 提交**

```bash
git add lib/models/botapi_event.dart test/botapi_event_test.dart
git commit -m "feat(botapi): BotApiEvent 模型 + ConnState"
```

---

## Task 2: HistoryRow 模型

**Files:**
- Create: `lib/models/history_row.dart`

- [ ] **Step 1: 实现（纯数据，无单测必要，但提供构造）**

```dart
// lib/models/history_row.dart

/// botapi GET /history 返回的单条消息（platform_message_history 表的稳定 int id）。
/// 被 BotApiHttp.fetchHistory 解析、CacheService.mergeHistory 去重共用。
class HistoryRow {
  final int messageId; // 整数行 id（字符串化而来）
  final String role; // user | assistant
  final String type; // text | thinking | tool_status
  final String content;
  final int timestamp;

  const HistoryRow({
    required this.messageId,
    required this.role,
    required this.type,
    required this.content,
    required this.timestamp,
  });

  factory HistoryRow.fromJson(Map<String, dynamic> json) => HistoryRow(
        messageId: int.parse(json['message_id'].toString()),
        role: json['role'] as String? ?? 'assistant',
        type: json['type'] as String? ?? 'text',
        content: (json['content'] as String?) ?? '',
        timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      );
}

class HistoryResult {
  final List<HistoryRow> messages;
  final bool hasMore;
  const HistoryResult({required this.messages, required this.hasMore});
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/models/history_row.dart
git commit -m "feat(botapi): HistoryRow 模型"
```

---

## Task 3: Account 模型 + AccountStore

**Files:**
- Create: `lib/models/account.dart`
- Create: `lib/services/account_store.dart`
- Test: `test/account_store_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
// test/account_store_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/services/account_store.dart';
import 'package:astrbot_app/models/account.dart';

class _Mem implements AccountStorage {
  final Map<String, String> _m = {};
  @override
  Future<String?> readString(String key) async => _m[key];
  @override
  Future<void> writeString(String key, String value) async => _m[key] = value;
}

void main() {
  late AccountStore s;
  setUp(() async {
    s = AccountStore(_Mem());
    await s.load();
  });

  test('空注册表 currentId 为空串占位', () {
    expect(s.currentId, kNoAccount);
    expect(s.accounts, isEmpty);
  });

  test('add 后 currentId 指向新账户', () async {
    final a = await s.add(serverUrl: 'https://h', token: 't1', label: '工作');
    expect(s.currentId, a.id);
    expect(s.accounts.first.displayName, '工作');
    expect(a.token, 't1');
  });

  test('无 label 时 displayName 派生', () async {
    final a = await s.add(serverUrl: 'https://h', token: 't1');
    expect(a.displayName, 'Bot ${a.id.substring(0, 4)}');
  });

  test('25 上限：第 26 个 add 返回 null', () async {
    for (int i = 0; i < 25; i++) {
      await s.add(serverUrl: 'h', token: 't$i');
    }
    expect(await s.add(serverUrl: 'h', token: 't25'), isNull);
  });

  test('select 切换 + touchCurrent 排序', () async {
    final a = await s.add(serverUrl: 'h', token: 't1');
    final b = await s.add(serverUrl: 'h', token: 't2');
    await s.select(a.id);
    expect(s.currentId, a.id);
    await s.touchCurrent(nowMs: 9999);
    expect(s.accounts.first.id, a.id); // 最近使用排前
    expect(b.id, a.id); // b 仍存在
  });

  test('updateCredentials 改 serverUrl/token', () async {
    final a = await s.add(serverUrl: 'h', token: 't1');
    final ok = await s.updateCredentials(a.id, serverUrl: 'h2', token: 't2');
    expect(ok, true);
    expect(s.accounts.first.serverUrl, 'h2');
    expect(s.accounts.first.token, 't2');
  });

  test('rename', () async {
    final a = await s.add(serverUrl: 'h', token: 't1');
    await s.rename(a.id, '新名');
    expect(s.accounts.first.displayName, '新名');
  });

  test('delete 当前账户 → 切到另一个或占位', () async {
    final a = await s.add(serverUrl: 'h', token: 't1');
    final b = await s.add(serverUrl: 'h', token: 't2');
    String deleted = '';
    await s.delete(b.id, deleteMessages: (_) async { deleted = b.id; });
    expect(deleted, b.id);
    expect(s.currentId, a.id); // 删的是当前 b → 切到 a
  });

  test('delete 非当前账户仅刷新列表', () async {
    final a = await s.add(serverUrl: 'h', token: 't1');
    final b = await s.add(serverUrl: 'h', token: 't2');
    await s.select(a.id);
    await s.delete(b.id, deleteMessages: (_) async {});
    expect(s.currentId, a.id);
    expect(s.accounts.length, 1);
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `flutter test test/account_store_test.dart`
Expected: FAIL

- [ ] **Step 3: 实现 Account 模型**

```dart
// lib/models/account.dart
//
// 账户 = 一个 botapi token + serverUrl（对接一个 bot/对话）。
// label 为用户自定义名；为空时 UI 用 id 前 4 位派生。
class Account {
  final String id;
  final String? label;
  final String serverUrl;
  final String token;
  final int createdAt;
  final int lastUsedAt;

  const Account({
    required this.id,
    required this.serverUrl,
    required this.token,
    required this.createdAt,
    required this.lastUsedAt,
    this.label,
  });

  String get displayName {
    final l = label;
    if (l != null && l.isNotEmpty) return l;
    return 'Bot ${id.length >= 4 ? id.substring(0, 4) : id}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        if (label != null) 'label': label,
        'serverUrl': serverUrl,
        'token': token,
        'createdAt': createdAt,
        'lastUsedAt': lastUsedAt,
      };

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        id: json['id'] as String,
        label: json['label'] as String?,
        serverUrl: json['serverUrl'] as String,
        token: json['token'] as String,
        createdAt: (json['createdAt'] as num).toInt(),
        lastUsedAt: (json['lastUsedAt'] as num).toInt(),
      );

  Account copyWith({
    String? id,
    Object? label = _unset,
    String? serverUrl,
    String? token,
    int? createdAt,
    int? lastUsedAt,
  }) =>
      Account(
        id: id ?? this.id,
        label: identical(label, _unset) ? this.label : label as String?,
        serverUrl: serverUrl ?? this.serverUrl,
        token: token ?? this.token,
        createdAt: createdAt ?? this.createdAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      );
}

class _Unset { const _Unset(); }
const _unset = _Unset();
```

- [ ] **Step 4: 实现 AccountStore**

```dart
// lib/services/account_store.dart
//
// 账户注册表纯逻辑（依赖 AccountStorage 抽象，便于单测用内存实现）。
// 职责：加载/持久化账户列表与当前账户 id；增删改；25 上限；切换当前账户；
// 删除当前账户时切到另一个（或占位）。
import 'dart:convert';
import '../models/account.dart';

abstract class AccountStorage {
  Future<String?> readString(String key);
  Future<void> writeString(String key, String value);
}

const _kAccountsKey = 'accounts_v1';
const _kCurrentIdKey = 'accounts_current_v1';
const int kMaxAccounts = 25;

/// 未添加任何账户时的占位 currentId。
const String kNoAccount = '';

class AccountStore {
  final AccountStorage _storage;
  AccountStore(this._storage);

  List<Account> _accounts = const [];
  String? _currentId;
  bool _loaded = false;

  List<Account> get accounts { _ensureLoaded(); return List.unmodifiable(_accounts); }
  String get currentId { _ensureLoaded(); return _currentId ?? kNoAccount; }

  void _ensureLoaded() {
    if (!_loaded) throw StateError('AccountStore 未加载，先调用 load()');
  }

  Future<void> load() async {
    final raw = await _storage.readString(_kAccountsKey);
    List<Account> list = const [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final arr = jsonDecode(raw);
        if (arr is List) {
          list = arr
              .map((e) => (e is Map) ? Map<String, dynamic>.from(e) : <String, dynamic>{})
              .map(Account.fromJson)
              .toList();
        }
      } catch (_) { list = const []; }
    }
    _accounts = _sortByLastUsed(list);
    _currentId = await _storage.readString(_kCurrentIdKey) ?? kNoAccount;
    if (_currentId == kNoAccount && _accounts.isNotEmpty) {
      _currentId = _accounts.first.id; // 容错：有账户但无 current 记录
    }
    _loaded = true;
  }

  /// 新增账户。返回新账户；已达 25 上限返回 null。
  /// label 可空。
  Future<Account?> add({
    required String serverUrl,
    required String token,
    String? label,
  }) async {
    _ensureLoaded();
    if (_accounts.length >= kMaxAccounts) return null;
    final now = _nowMs();
    final a = Account(
      id: _uuid(),
      serverUrl: serverUrl,
      token: token,
      label: label,
      createdAt: now,
      lastUsedAt: now,
    );
    _accounts = _sortByLastUsed([..._accounts, a]);
    _currentId = a.id;
    await _persist();
    return a;
  }

  Future<bool> select(String id) async {
    _ensureLoaded();
    final idx = _accounts.indexWhere((a) => a.id == id);
    if (idx < 0) return false;
    final now = _nowMs();
    final list = [..._accounts]..[idx] = _accounts[idx].copyWith(lastUsedAt: now);
    _accounts = _sortByLastUsed(list);
    _currentId = id;
    await _persist();
    return true;
  }

  Future<bool> rename(String id, String? label) async {
    _ensureLoaded();
    final idx = _accounts.indexWhere((a) => a.id == id);
    if (idx < 0) return false;
    final trimmed = label?.trim();
    final list = [..._accounts]..[idx] = _accounts[idx].copyWith(
        label: (trimmed == null || trimmed.isEmpty) ? null : trimmed);
    _accounts = list;
    await _persist();
    return true;
  }

  Future<bool> updateCredentials(String id, {required String serverUrl, required String token}) async {
    _ensureLoaded();
    final idx = _accounts.indexWhere((a) => a.id == id);
    if (idx < 0) return false;
    final list = [..._accounts]..[idx] = _accounts[idx].copyWith(serverUrl: serverUrl, token: token);
    _accounts = list;
    await _persist();
    return true;
  }

  /// 删除账户。返回删除后应切换到的 currentId。
  Future<String> delete(String id, {required Future<void> Function(String) deleteMessages}) async {
    _ensureLoaded();
    _accounts = [..._accounts]..where((a) => a.id != id).toList();
    _accounts = _accounts.where((a) => a.id != id).toList();
    await deleteMessages(id);
    String next;
    if (_currentId == id) {
      next = _accounts.isEmpty ? kNoAccount : _accounts.first.id;
      _currentId = next;
      await _persist();
    } else {
      await _persist();
      next = _currentId ?? kNoAccount;
    }
    return next;
  }

  Future<void> touchCurrent({required int nowMs}) async {
    _ensureLoaded();
    if (_currentId == null || _currentId == kNoAccount) return;
    final idx = _accounts.indexWhere((a) => a.id == _currentId);
    if (idx < 0) return;
    final list = [..._accounts]..[idx] = _accounts[idx].copyWith(lastUsedAt: nowMs);
    _accounts = _sortByLastUsed(list);
    await _persist();
  }

  Future<void> _persist() async {
    final arr = _accounts.map((a) => a.toJson()).toList();
    await _storage.writeString(_kAccountsKey, jsonEncode(arr));
    await _storage.writeString(_kCurrentIdKey, _currentId ?? kNoAccount);
  }
}

List<Account> _sortByLastUsed(List<Account> list) {
  final copy = [...list]..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
  return copy;
}

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

String _uuid() {
  // 简单 uuid（无需强唯一性；本地 id）。避免引入 uuid 依赖。
  final now = DateTime.now().millisecondsSinceEpoch;
  return '${now.toRadixString(36)}${_nowMicrosecond()}';
}

int _nowMicrosecond() {
  // DateTime 无 microsecond 在常量限制下用随机替代——这里用时间戳低位。
  return DateTime.now().microsecondsSinceEpoch & 0xFFFFFF;
}
```

- [ ] **Step 5: 实现 PrefsAccountStorage（并入同文件末尾）**

```dart
// 追加到 lib/services/account_store.dart
import 'package:shared_preferences/shared_preferences.dart';

class PrefsAccountStorage implements AccountStorage {
  final SharedPreferences _prefs;
  PrefsAccountStorage(this._prefs);
  @override
  Future<String?> readString(String key) async => _prefs.getString(key);
  @override
  Future<void> writeString(String key, String value) async =>
      _prefs.setString(key, value);
}
```

注意：`_uuid()` 在测试中会因 `DateTime.now()` 而被多个 add 快速调用可能产生相同 id（毫秒+微秒低位）。为避免 25 个 add 在同一毫秒内 id 碰撞，在 `_uuid()` 里加计数器：把 `_uuid` 改为使用一个静态递增计数器拼接时间戳。修订实现：

```dart
int _uuidCounter = 0;
String _uuid() {
  _uuidCounter += 1;
  return '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${_uuidCounter.toRadixString(36)}';
}
```

- [ ] **Step 6: 运行确认通过**

Run: `flutter test test/account_store_test.dart`
Expected: PASS（全部）

- [ ] **Step 7: 提交**

```bash
git add lib/models/account.dart lib/services/account_store.dart test/account_store_test.dart
git commit -m "feat(botapi): Account 模型 + AccountStore"
```

---

## Task 4: BotApiHttp（无状态 REST）

**Files:**
- Create: `lib/services/botapi_http.dart`
- Test: `test/botapi_http_base_test.dart`

- [ ] **Step 1: 写失败测试（base 规整纯函数）**

```dart
// test/botapi_http_base_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/services/botapi_http.dart';

void main() {
  group('botapiBase', () {
    test('已含 /api/v1/botapi 不重复拼接', () {
      expect(botapiBase('https://h/api/v1/botapi'), 'https://h/api/v1/botapi');
    });
    test('带尾斜杠去掉', () {
      expect(botapiBase('https://h/api/v1/botapi/'), 'https://h/api/v1/botapi');
    });
    test('纯 host 补全路径', () {
      expect(botapiBase('https://h'), 'https://h/api/v1/botapi');
    });
    test('host 带尾斜杠', () {
      expect(botapiBase('https://h/'), 'https://h/api/v1/botapi');
    });
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `flutter test test/botapi_http_base_test.dart`
Expected: FAIL

- [ ] **Step 3: 实现**

```dart
// lib/services/botapi_http.dart
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';
import 'package:path_provider/path_provider.dart';
import '../models/history_row.dart';

/// 规整 serverUrl 为 botapi base：保证以 /api/v1/botapi 结尾、无尾斜杠。
String botapiBase(String serverUrl) {
  var s = serverUrl.trim();
  if (s.isEmpty) return s;
  if (s.endsWith('/')) s = s.substring(0, s.length - 1);
  if (s.endsWith('/api/v1/botapi')) return s;
  if (s.endsWith('/api/v1/botapi/')) return s.substring(0, s.length - 1);
  return '$s/api/v1/botapi';
}

class UploadResult {
  final String fileId;
  final String name;
  final String mimeType;
  final int size;
  const UploadResult({required this.fileId, required this.name, required this.mimeType, required this.size});
}

/// botapi 无状态 REST 客户端。给定 (serverUrl, token)。
class BotApiHttp {
  final String serverUrl;
  final String token;
  BotApiHttp({required this.serverUrl, required this.token});

  String get _base => botapiBase(serverUrl);
  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer $token',
      };

  /// 校验 token。true=有效；false=无效/不可达(401)。
  Future<bool> auth() async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 12),
      ));
      final res = await dio.post('$_base/auth',
          data: {'token': token},
          options: Options(headers: {'Content-Type': 'application/json'}));
      return res.statusCode == 200;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) return false;
      return false; // 网络不可达也视为校验失败（调用方据此提示）
    } catch (_) {
      return false;
    }
  }

  /// 发消息。返回 message_id；失败返回 null。
  Future<String?> sendMessage({String? text, List<String>? fileIds}) async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ));
      final res = await dio.post('$_base/message',
          data: {
            if (text != null && text.isNotEmpty) 'text': text,
            if (fileIds != null && fileIds.isNotEmpty) 'file_ids': fileIds,
          },
          options: Options(headers: {..._authHeaders, 'Content-Type': 'application/json'}));
      if (res.statusCode == 200) {
        return (res.data as Map?)?['message_id'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 上传文件。返回 UploadResult；失败 null。
  Future<UploadResult?> uploadFile(File file, String contentType,
      {void Function(int sent, int total)? onProgress}) async {
    try {
      final filename = file.path.split('/').last;
      final dio = Dio(BaseOptions(
        baseUrl: _base,
        connectTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 120),
        receiveTimeout: const Duration(seconds: 60),
      ));
      final form = FormData.fromMap({
        'file': await MultipartFile.fromFile(file.path,
            filename: filename, contentType: MediaType.parse(contentType)),
      });
      final res = await dio.post('/upload',
          data: form,
          options: Options(headers: _authHeaders),
          onSendProgress: onProgress);
      if (res.statusCode == 200 && res.data is Map) {
        final m = res.data as Map<String, dynamic>;
        return UploadResult(
          fileId: m['file_id'] as String,
          name: m['name'] as String,
          mimeType: m['mime_type'] as String,
          size: (m['size'] as num).toInt(),
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 拉历史。since/before 为整数 id（可空）。
  Future<HistoryResult> fetchHistory({int? since, int? before, int limit = 200}) async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ));
      final q = <String, dynamic>{'limit': limit};
      if (since != null) q['since'] = since;
      if (before != null) q['before'] = before;
      final res = await dio.get('$_base/history',
          queryParameters: q, options: Options(headers: _authHeaders));
      if (res.statusCode == 200 && res.data is Map) {
        final m = res.data as Map<String, dynamic>;
        final list = (m['messages'] as List?) ?? [];
        return HistoryResult(
          messages: list
              .map((e) => HistoryRow.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList(),
          hasMore: (m['has_more'] as bool?) ?? false,
        );
      }
      return const HistoryResult(messages: [], hasMore: false);
    } catch (_) {
      return const HistoryResult(messages: [], hasMore: false);
    }
  }

  /// 下载媒体 URL（单次有效，免认证）。写入 attachments 目录，返回本地 File。
  /// 失败返回 null。
  Future<File?> downloadByUrl(String url) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${dir.path}/attachments');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      // 用 url 末段作文件名，截断避免过长。
      final tail = Uri.parse(url).pathSegments.last;
      final name = (tail.isEmpty ? DateTime.now().millisecondsSinceEpoch.toString() : tail)
          .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final path = '${cacheDir.path}/$name';
      final existing = File(path);
      if (await existing.exists() && await existing.length() > 0) return existing;
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ));
      final res = await dio.get<List<int>>(url,
          options: Options(responseType: ResponseType.bytes));
      final ct = res.headers.value('content-type') ?? '';
      if (res.statusCode != 200 || ct.contains('application/json')) return null;
      final bytes = res.data ?? const <int>[];
      if (bytes.isEmpty) return null;
      await existing.writeAsBytes(bytes);
      return existing;
    } catch (_) {
      return null;
    }
  }

  /// 清理 7 天前的附件缓存（botapi 媒体单次有效，本地缓存即下载文件）。
  static Future<void> cleanOldCache() async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${dir.path}/attachments');
    if (!await cacheDir.exists()) return;
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    await for (final e in cacheDir.list()) {
      if (e is File) {
        final stat = await e.stat();
        if (stat.modified.isBefore(cutoff)) await e.delete();
      }
    }
  }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `flutter test test/botapi_http_base_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add lib/services/botapi_http.dart test/botapi_http_base_test.dart
git commit -m "feat(botapi): BotApiHttp REST 客户端"
```

---

## Task 5: BotApiClient（SSE 流 + 重连）

**Files:**
- Create: `lib/services/botapi_client.dart`

> 说明：SSE 客户端涉及网络与 Timer，不写单测（与原 `astrbot_sse_client` 一致，靠集成验证）。复用 `util/reconnect.dart` 的 `ReconnectAttempt`、`util/retry.dart` 的 `withRetry`。

- [ ] **Step 1: 实现**

```dart
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

  final _eventController = StreamController<BotApiEvent>.broadcast();
  final _stateController = StreamController<ConnState>.broadcast();

  Stream<BotApiEvent> get events => _eventController.stream;
  Stream<ConnState> get state => _stateController.stream;

  BotApiClient({required this.serverUrl, required this.token});

  String get _base {
    var s = serverUrl.trim();
    if (s.endsWith('/')) s = s.substring(0, s.length - 1);
    if (s.endsWith('/api/v1/botapi')) return s;
    return '$s/api/v1/botapi';
  }

  /// 开 SSE 流。sinceCursor 为上次最大 history int id，用于断连补漏。
  Future<void> connect({int? sinceCursor}) async {
    if (_disposed) return;
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
      _httpClient = http.Client();
      final streamedResponse = await withRetry(
        () => _httpClient!.send(request).timeout(const Duration(seconds: 300)),
        isTransient: isTransientHttpError,
        maxAttempts: 3,
        delayFor: (i) => Duration(milliseconds: 1000 << i),
      );
      if (streamedResponse.statusCode != 200) {
        // 401 等：token 问题或服务端拒绝，不再自重连，交给上层。
        _eventController.add(BotApiEvent.fromSse('error',
            {'code': 'CONNECT_FAILED', 'message': 'HTTP ${streamedResponse.statusCode}'}));
        _setState(ConnState.disconnected);
        return;
      }
      _reconnect.reset();
      _setState(ConnState.connected);
      _parseStream(streamedResponse);
    } catch (e) {
      _scheduleReconnect(sinceCursor: sinceCursor);
    }
  }

  void _parseStream(http.StreamedResponse resp) async {
    String? eventType;
    final dataBuf = StringBuffer();
    try {
      final lines = resp.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (_disposed) break;
        if (line.startsWith('event:')) {
          eventType = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          dataBuf.write(line.substring(5).trim());
        } else if (line.isEmpty && eventType != null && dataBuf.isNotEmpty) {
          final raw = dataBuf.toString();
          dataBuf.clear();
          try {
            final json = jsonDecode(raw) as Map<String, dynamic>;
            _eventController.add(BotApiEvent.fromSse(eventType!, json));
          } catch (_) {
            // ping 的 data 可能是 {}，已解析；解析失败忽略
            if (eventType == 'ping') {
              _eventController.add(BotApiEvent.fromSse('ping', {}));
            }
          }
          eventType = null;
        }
      }
    } catch (_) {}
    // 流自然结束（服务端关闭/网络断）→ 重连
    if (!_disposed) {
      _setState(ConnState.disconnected);
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect({int? sinceCursor}) {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    final delay = _reconnect.nextDelay(baseMs: 1000, maxMs: 30000);
    _setState(ConnState.reconnecting);
    _reconnect.recordFailure();
    debugPrint('[BotAPI] reconnecting in ${delay}ms...');
    _reconnectTimer = Timer(Duration(milliseconds: delay), () {
      if (!_disposed) connect(sinceCursor: sinceCursor);
    });
  }

  void _setState(ConnState s) => _stateController.add(s);

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _httpClient?.close();
    await _eventController.close();
    await _stateController.close();
  }
}
```

> 注意：`_parseStream` 中 `data:` 行用 `line.substring(5).trim()` —— botapi SSE 格式为 `data: {json}`（冒号后一空格）。`.trim()` 同时去掉前导空格与可能的尾空白，稳健。

- [ ] **Step 2: analyze 确认无错**

Run: `flutter analyze lib/services/botapi_client.dart`
Expected: No issues

- [ ] **Step 3: 提交**

```bash
git add lib/services/botapi_client.dart
git commit -m "feat(botapi): BotApiClient SSE 流客户端"
```

---

## Task 6: LocalMessage 增 serverId

**Files:**
- Modify: `lib/models/message.dart`
- Modify: `lib/services/cache_service.dart`（onCreate/onUpgrade schema 与 toMap/fromMap）

- [ ] **Step 1: 改 message.dart**

在 `LocalMessage` 类增加字段 `final int? serverId;`，在构造、`toMap`、`fromMap`、`copyWith` 中处理。

`toMap` 增加 `if (serverId != null) 'server_id': serverId,`。
`fromMap` 增加 `serverId: (map['server_id'] as num?)?.toInt(),`。
`copyWith` 增加 `int? serverId` 参数（直接覆盖即可，可空类型无需哨兵）：

```dart
// copyWith 签名增加：
int? serverId,
// 构造体内：
serverId: serverId ?? this.serverId,
```

- [ ] **Step 2: 改 cache_service.dart schema**

`_initDb` 的 `onCreate` SQL 增加 `server_id INTEGER` 列：

```dart
CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  msg_type TEXT NOT NULL,
  content TEXT,
  attachment_id TEXT,
  local_path TEXT,
  is_from_me INTEGER NOT NULL,
  status TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  session_id TEXT,
  server_id INTEGER
)
```

`onCreate` 中 `_buildSessionIndex` 之后增加：
```dart
await db.execute('CREATE INDEX IF NOT EXISTS idx_messages_server ON messages(server_id)');
```

`version: 5` → `version: 6`。

`onUpgrade` 增加：
```dart
if (oldV < 6) {
  await db.execute('ALTER TABLE messages ADD COLUMN server_id INTEGER');
  try {
    await db.execute('CREATE INDEX IF NOT EXISTS idx_messages_server ON messages(server_id)');
  } catch (_) {}
}
```

- [ ] **Step 3: analyze + 既有测试仍通过**

Run: `flutter analyze lib/models/message.dart lib/services/cache_service.dart && flutter test`
Expected: No issues；既有测试 PASS

- [ ] **Step 4: 提交**

```bash
git add lib/models/message.dart lib/services/cache_service.dart
git commit -m "feat(cache): messages 表增 server_id 列(v6)"
```

---

## Task 7: CacheService.mergeHistory

**Files:**
- Modify: `lib/services/cache_service.dart`
- Test: `test/cache_service_history_test.dart`

> 用 sqflite 测试需 `sqflite_common_ffi`。为避免新增依赖，本测试改用「纯逻辑」方式：把 `mergeHistory` 的去重判定抽成可测的纯函数 `_dedupDecision`，再在集成层调用。实际：直接在内存 DB（sqflite 不支持纯内存于 flutter_test 无 ffi）。**取舍**：本任务不引入 ffi 依赖，改为对 `mergeHistory` 做「形状/签名」编译保证 + 在 Task 15 真机集成时人工验证去重。单测覆盖纯函数 `historyMergePlan`。

修订方案：在 cache_service.dart 增加一个顶层纯函数 `HistoryMergeAction` 判定（不碰 DB），单测覆盖它；`mergeHistory` 内部调用该函数决定每行动作。

- [ ] **Step 1: 写失败测试（纯函数）**

```dart
// test/cache_service_history_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/services/cache_service.dart';
import 'package:astrbot_app/models/history_row.dart';

void main() {
  group('historyMergePlan', () {
    test('server_id 已存在 → skip', () {
      final plan = historyMergePlan(
        row: const HistoryRow(messageId: 5, role: 'assistant', type: 'text', content: 'x', timestamp: 1),
        existingServerIds: const {5},
        existingLiveMatch: false,
      );
      expect(plan, HistoryMergeAction.skip);
    });
    test('存在同内容实时行 → link', () {
      final plan = historyMergePlan(
        const HistoryRow(messageId: 5, role: 'assistant', type: 'text', content: 'x', timestamp: 1),
        existingServerIds: const {},
        existingLiveMatch: true,
      );
      expect(plan, HistoryMergeAction.link);
    });
    test('全新 → insert', () {
      final plan = historyMergePlan(
        const HistoryRow(messageId: 5, role: 'user', type: 'text', content: 'hi', timestamp: 1),
        existingServerIds: const {},
        existingLiveMatch: false,
      );
      expect(plan, HistoryMergeAction.insert);
    });
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `flutter test test/cache_service_history_test.dart`
Expected: FAIL

- [ ] **Step 3: 实现纯函数 + mergeHistory**

在 `lib/services/cache_service.dart` 顶部（class 外）增加：

```dart
import '../models/history_row.dart';

enum HistoryMergeAction { skip, link, insert }

/// 决定一条历史行如何合并：
/// - server_id 已在本地存在 → skip
/// - 存在同内容实时行（live，server_id 为空）→ link（贴 server_id）
/// - 否则 → insert
HistoryMergeAction historyMergePlan({
  required HistoryRow row,
  required Set<int> existingServerIds,
  required bool existingLiveMatch,
}) {
  if (existingServerIds.contains(row.messageId)) return HistoryMergeAction.skip;
  if (existingLiveMatch) return HistoryMergeAction.link;
  return HistoryMergeAction.insert;
}
```

在 `CacheService` 类内增加方法（参数名统一 `accountId`，DB 列仍 `session_id`）：

```dart
/// 合并 botapi 历史行：按 server_id 去重；已存在同内容实时行则贴 server_id；
/// 全新则插入。返回合并后该账户的最大 server_id（用于 stream since 游标）。
Future<int> mergeHistory(List<HistoryRow> rows, {required String accountId}) async {
  if (rows.isEmpty) return 0;
  final d = await db;
  int maxId = 0;
  for (final row in rows) {
    if (row.messageId > maxId) maxId = row.messageId;
    final existing = await d.query('messages',
        where: 'session_id = ? AND server_id = ?',
        whereArgs: [accountId, row.messageId],
        limit: 1);
    if (existing.isNotEmpty) continue; // skip
    // 查同内容实时行（server_id 为空，内容+角色+时间窗匹配）
    final live = await d.query('messages',
        where: 'session_id = ? AND server_id IS NULL AND is_from_me = ? AND content = ? AND created_at > ?',
        whereArgs: [accountId, row.role == 'user' ? 1 : 0, row.content, (row.timestamp * 1000) - 300000],
        limit: 1);
    if (live.isNotEmpty) {
      await d.update('messages', {'server_id': row.messageId},
          where: 'id = ?', whereArgs: [live.first['id']]);
    } else {
      await d.insert('messages', {
        'msg_type': row.type == 'thinking' ? 'thinking' : 'text',
        'content': row.content,
        'is_from_me': row.role == 'user' ? 1 : 0,
        'status': 'sent',
        'created_at': row.timestamp * 1000,
        'session_id': accountId,
        'server_id': row.messageId,
      });
    }
  }
  return maxId;
}

/// 当前账户本地最大 server_id（用于 stream since 游标；无则 0）。
Future<int> maxServerId(String accountId) async {
  final d = await db;
  final rows = await d.rawQuery(
      'SELECT MAX(server_id) AS m FROM messages WHERE session_id = ?', [accountId]);
  final m = rows.first['m'];
  return (m as num?)?.toInt() ?? 0;
}
```

同时把既有方法的形参 `sessionId` 重命名为 `accountId`（`insertMessage/upsert/upsertBotText/hasAttachmentId/getMessages/clearSession/backfillSession/adoptOrphans`）。WHERE 列名仍是 `session_id`。`backfillSession`/`adoptOrphans` 形参改名 `accountId`。

- [ ] **Step 4: 运行确认通过**

Run: `flutter test test/cache_service_history_test.dart`
Expected: PASS

- [ ] **Step 5: analyze + 全部测试**

Run: `flutter analyze && flutter test`
Expected: No issues；测试 PASS

- [ ] **Step 6: 提交**

```bash
git add lib/services/cache_service.dart test/cache_service_history_test.dart
git commit -m "feat(cache): mergeHistory 按 server_id 去重 + 纯函数单测"
```

---

## Task 8: ConfigService 迁移（删 webchat 字段 + v3）

**Files:**
- Modify: `lib/services/config_service.dart`
- Modify: `lib/config/app_config.dart`

- [ ] **Step 1: 改 app_config.dart**

```dart
// lib/config/app_config.dart
class AppConfig {
  static const String appName = 'Bot助手';
  static const int cacheRetentionDays = 7;
}
```

（移除 defaultServerUrl/defaultConfigId/defaultConnectionMode/ws* 常量）

- [ ] **Step 2: 重写 config_service.dart**

```dart
// lib/services/config_service.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ConfigService {
  static const _kIsConfigured = 'is_configured';
  static const _kThemeMode = 'theme_mode';
  static const _kAutoPlayVoice = 'auto_play_voice';
  // Bumped when we need a one-time prefs migration.
  // v3: 迁移到 botapi——清空旧 webchat 数据，重置 is_configured。
  static const _kPrefsVersion = 'prefs_version';
  static const int _kCurrentPrefsVersion = 3;

  late SharedPreferences _prefs;

  /// 暴露底层 prefs，供 AccountStore 复用同一存储实例。
  SharedPreferences get prefs => _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _migrate();
  }

  Future<void> _migrate() async {
    final v = _prefs.getInt(_kPrefsVersion) ?? 1;
    if (v >= _kCurrentPrefsVersion) return;
    if (v < 3) {
      // 旧 webchat 数据与 botapi 不兼容：清账户/会话注册表、消息表，重置配置态。
      // 主题与 autoPlay 等偏好保留。
      _prefs.remove('chat_sessions_v1');
      _prefs.remove('chat_sessions_current_v1');
      _prefs.remove('accounts_v1');
      _prefs.remove('accounts_current_v1');
      _prefs.remove('nickname');
      _prefs.remove('server_url');
      _prefs.remove('api_key');
      _prefs.remove('config_id');
      _prefs.remove('session_id');
      _prefs.remove('connection_mode');
      await _prefs.setBool(_kIsConfigured, false);
      // 消息表清空（DB 层在打开时清；此处标记，CacheService 首次打开检测）
      _prefs.setBool('botapi_wipe_messages', true);
    }
    await _prefs.setInt(_kPrefsVersion, _kCurrentPrefsVersion);
  }

  bool get isConfigured => _prefs.getBool(_kIsConfigured) ?? false;
  Future<void> setConfigured(bool v) => _prefs.setBool(_kIsConfigured, v);

  bool get autoPlayVoice => _prefs.getBool(_kAutoPlayVoice) ?? false;
  Future<void> setAutoPlayVoice(bool v) => _prefs.setBool(_kAutoPlayVoice, v);

  ThemeMode get themeMode {
    final v = _prefs.getString(_kThemeMode) ?? 'auto';
    switch (v) {
      case 'light': return ThemeMode.light;
      case 'dark': return ThemeMode.dark;
      default: return ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    String v;
    switch (mode) {
      case ThemeMode.light: v = 'light';
      case ThemeMode.dark: v = 'dark';
      default: v = 'auto';
    }
    await _prefs.setString(_kThemeMode, v);
  }
}
```

- [ ] **Step 3: CacheService 兼容 wipe 标记**

在 `cache_service.dart` 的 `_initDb` 的 `onCreate` 后无法读 prefs；改为在 provider 初始化时处理：`CacheService.open()` 后若 `prefs.getBool('botapi_wipe_messages')==true` 则 `clearAll()` 并清除标记。在 `CacheService` 增加方法：

```dart
Future<void> wipeIfFlagged(SharedPreferences prefs) async {
  if (prefs.getBool('botapi_wipe_messages') == true) {
    await clearAll();
    await prefs.remove('botapi_wipe_messages');
  }
}
```

- [ ] **Step 4: analyze**

Run: `flutter analyze lib/services/config_service.dart lib/config/app_config.dart lib/services/cache_service.dart`
Expected: No issues（此时 chat_provider 等仍引用旧字段，会有错——本任务暂不修 provider，由 Task 9 统一重写；analyze 全项目会报错，仅分析这三个文件）

- [ ] **Step 5: 提交**

```bash
git add lib/services/config_service.dart lib/config/app_config.dart lib/services/cache_service.dart
git commit -m "feat(config): 删 webchat 字段 + v3 迁移清空旧数据"
```

---

## Task 9: ChatProvider 重写

**Files:**
- Rewrite: `lib/providers/chat_provider.dart`

> 这是核心重写。完整替换文件。移除 WS、session_store、configId 解析、标题获取；接入 AccountStore/BotApiClient/BotApiHttp/mergeHistory。

- [ ] **Step 1: 完整重写 chat_provider.dart**

```dart
// lib/providers/chat_provider.dart
import 'dart:async';
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
import '../util/lifecycle_reconnect.dart';
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
  final List<String> toolStatuses; // 本轮工具状态文本（系统气泡，不并入答案）
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
    this.toolStatuses = const [],
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
    List<String>? toolStatuses,
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
        toolStatuses: toolStatuses ?? this.toolStatuses,
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
  // 未连接时暂存的消息（文本 parts），connected 后 drain。
  final List<_PendingSend> _pendingQueue = [];
  AudioPlaybackNotifier? _playback;
  // SSE 在途：当前正在等服务端响应的「我发出」文本消息的 createdAt（用于失败关联）。
  int? _inflightTextCreatedAt;
  // 当前账户流式进行中的 message_id（用于多事件归属；botapi 一轮一个）。
  String? _streamingMessageId;
  bool _sessionKicked = false;

  ChatNotifier(this._config)
      : _accounts = AccountStore(PrefsAccountStorage(_config.prefs)),
        super(ChatState(autoPlayVoice: _config.autoPlayVoice)) {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _onAppResumed();
  }

  void _onAppResumed() {
    Future.delayed(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      if (shouldReconnectOnResume(
          current: AppLifecycleState.resumed,
          isConnected: state.connectionState == ConnState.connected)) {
        connect();
      }
    });
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
    await _client?.dispose();
    _client = null;

    try {
      state = state.copyWith(errorMessage: null, streamingText: null,
          streamingThinking: null, toolStatuses: const []);
      _sessionKicked = false;
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

      // 校验 token
      final ok = await _http!.auth();
      if (!ok) {
        state = state.copyWith(
            connectionState: ConnState.disconnected,
            errorMessage: 'token 无效或服务器不可达，请在账户管理中更新');
        return;
      }

      // 拉服务端历史并合并补漏
      final hist = await _http!.fetchHistory(since: 0);
      await _cache.mergeHistory(hist.messages, accountId: acc.id);
      final refreshed = await _cache.getMessages(accountId: acc.id);
      final cursor = await _cache.maxServerId(acc.id);
      _syncAccountState(messages: refreshed);

      // 开 SSE 流
      _client = BotApiClient(serverUrl: acc.serverUrl, token: acc.token);
      _stateSub = _client!.state.listen((s) {
        if (s == ConnState.disconnected || s == ConnState.reconnecting) {
          _flushInterruptedStream();
        }
        state = state.copyWith(connectionState: s);
        if (s == ConnState.connected && _pendingQueue.isNotEmpty) {
          final failed = <_PendingSend>[];
          for (final p in _pendingQueue) {
            _dispatchPending(p);
          }
          _pendingQueue.clear();
          _pendingQueue.addAll(failed);
        }
      });
      _eventSub = _client!.events.listen(_handleEvent);
      await _client!.connect(sinceCursor: cursor);

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

  /// 把暂存消息真正发出（connected 后 drain）。
  void _dispatchPending(_PendingSend p) {
    if (p.isText) {
      _doSendText(createdAt: p.createdAt, text: p.text!, fileIds: null);
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
    final acc = _currentAccount;
    final http = _http;
    if (acc == null || http == null) {
      _pendingQueue.add(_PendingSend(createdAt: createdAt, text: text, fileIds: fileIds));
      state = state.copyWith(errorMessage: '账户未就绪');
      return;
    }
    final conn = state.connectionState;
    if (conn != ConnState.connected) {
      _pendingQueue.add(_PendingSend(createdAt: createdAt, text: text, fileIds: fileIds));
      return;
    }
    _inflightTextCreatedAt = createdAt;
    http.sendMessage(text: text, fileIds: fileIds).then((mid) {
      if (!mounted) return;
      if (mid == null) {
        // 发送失败：标记 error（可重发）
        final msgs = _markOutboundError(state.messages, createdAt);
        state = state.copyWith(messages: msgs, errorMessage: '发送失败');
        for (final m in msgs) {
          if (m.createdAt == createdAt && m.isFromMe) _cache.upsert(m, accountId: _cacheAccountId);
        }
      } else {
        // 成功：标 sent
        state = state.copyWith(
            messages: state.messages
                .map((m) => m.createdAt == createdAt && m.isFromMe
                    ? m.copyWith(status: MessageStatus.sent)
                    : m)
                .toList());
        // 用户消息贴 server_id 在 history 合并时完成。
      }
    });
  }

  Future<void> retryTextSend(int createdAt) async {
    final idx = state.messages.indexWhere((m) => m.createdAt == createdAt && m.isFromMe);
    if (idx < 0) return;
    final text = state.messages[idx].content;
    if (text == null || text.isEmpty) return;
    state = state.copyWith(
        messages: _setMessagePending(state.messages, createdAt));
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

  /// 上传完成 → 发 message(file_ids)。msgType: image/voice/file。
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

  Future<void> retryMediaSend(int createdAt, String msgType, String? localPath, String? content) async {
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
    final http = _http ?? (_currentAccount != null
        ? BotApiHttp(serverUrl: _currentAccount!.serverUrl, token: _currentAccount!.token)
        : null);
    if (http == null) return;
    String mime;
    switch (msgType) {
      case 'voice': mime = 'audio/wav'; break;
      case 'image': mime = 'image/jpeg'; break;
      default:
        mime = (content != null && content.toLowerCase().endsWith('.pdf'))
            ? 'application/pdf' : 'application/octet-stream';
    }
    final result = await http.uploadFile(file, mime, onProgress: (s, t) {
      updateUploadProgress(createdAt, t > 0 ? s / t : 0);
    });
    if (result != null && mounted) {
      finalizeMediaSend(createdAt, result.fileId, msgType);
    } else if (mounted) {
      failMediaUpload(createdAt);
    }
  }

  /// 下载 botapi 媒体 URL（收到即下载，单次有效）。返回本地路径或 null。
  Future<String?> _downloadMedia(String url) async {
    final http = _http;
    if (http == null) return null;
    final f = await http.downloadByUrl(url);
    return f?.path;
  }

  // ── 事件处理 ──

  void _handleEvent(BotApiEvent event) {
    final now = DateTime.now().millisecondsSinceEpoch;

    if (event.isPing) return;

    if (event.isError) {
      if (event.code == 'SESSION_KICKED') {
        _sessionKicked = true;
        state = state.copyWith(errorMessage: event.message ?? '会话已被管理员断开');
      } else {
        // SSE 在途文本失败关联
        if (_inflightTextCreatedAt != null) {
          final inflight = _inflightTextCreatedAt!;
          _inflightTextCreatedAt = null;
          final msgs = _markOutboundError(state.messages, inflight);
          for (final m in msgs) {
            if (m.createdAt == inflight && m.isFromMe) _cache.upsert(m, accountId: _cacheAccountId);
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
      // 工具状态：独立系统气泡，不并入答案
      if (event.isToolStatus) {
        state = state.copyWith(
            toolStatuses: [...state.toolStatuses, event.content ?? '']);
        return;
      }
      // 媒体
      if (event.isMedia) {
        _handleMedia(event, now);
        return;
      }
      // 文本
      if (event.isStreamingText) {
        _streamingMessageId = event.messageId ?? _streamingMessageId;
        final cur = state.streamingText ?? '';
        state = state.copyWith(streamingText: cur + (event.content ?? ''));
        return;
      }
      if (event.isFinalText) {
        _streamingMessageId = event.messageId;
        final full = event.content ?? '';
        _commitBotText(full, now);
        return;
      }
      // message text 非 streaming 非 final（罕见，按完整处理）
      if (event.type == 'text' && (event.content ?? '').isNotEmpty) {
        _commitBotText(event.content!, now);
      }
    }
  }

  Future<void> _handleMedia(BotApiEvent event, int now) async {
    final type = event.type!;
    String? url;
    String? label;
    if (type == 'file') {
      try {
        final obj = event.content != null
            ? Map<String, dynamic>.from(
                _decode(event.content!))
            : <String, dynamic>{};
        url = obj['url'] as String?;
        label = obj['name'] as String?;
      } catch (_) {}
    } else {
      url = event.content;
    }
    final cat = _mediaCategory(type);
    // 占位先入列
    final placeholder = LocalMessage(
      msgType: type,
      content: label,
      isFromMe: false,
      status: MessageStatus.sent,
      createdAt: now,
    );
    state = state.copyWith(messages: [...state.messages, placeholder]);
    _cache.upsert(placeholder, accountId: _cacheAccountId);
    // 下载
    if (url != null) {
      final localPath = await _downloadMedia(url);
      if (localPath != null && mounted) {
        final msgs = [...state.messages];
        for (int i = msgs.length - 1; i >= 0; i--) {
          if (!msgs[i].isFromMe && msgs[i].createdAt == now && msgs[i].msgType == type) {
            msgs[i] = msgs[i].copyWith(localPath: localPath);
            state = state.copyWith(messages: msgs);
            _cache.upsert(msgs[i], accountId: _cacheAccountId);
            if (cat == 'audio' && _playback != null && _config.autoPlayVoice) {
              _playback!.enqueue(msgs[i]);
            }
            break;
          }
        }
      }
    }
  }

  Map<String, dynamic> _decode(String s) {
    return Map<String, dynamic>.from(
        _jsonDecoder.convert(s) as Map);
  }

  static final _jsonDecoder = const JsonDecoder();

  void _commitBotText(String full, int now) {
    final botMsg = LocalMessage(
      msgType: 'text',
      content: full,
      isFromMe: false,
      status: MessageStatus.sent,
      createdAt: now,
    );
    _cache.upsertBotText(botMsg, accountId: _cacheAccountId);
    state = state.copyWith(
      messages: [...state.messages, botMsg],
      streamingText: null,
      streamingThinking: null,
      toolStatuses: const [],
    );
    _streamingMessageId = null;
    _inflightTextCreatedAt = null;
  }

  void _flushInterruptedStream() {
    final interrupted = state.streamingText;
    if (interrupted == null || interrupted.trim().isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final botMsg = LocalMessage(
      msgType: 'text',
      content: '$interrupted\n\n_(回复中断,请重试)_',
      isFromMe: false,
      status: MessageStatus.sent,
      createdAt: now,
    );
    _cache.upsertBotText(botMsg, accountId: _cacheAccountId);
    state = state.copyWith(messages: [...state.messages, botMsg], streamingText: null);
  }

  // ── 账户管理 ──

  Future<bool> addAccount({required String serverUrl, required String token, String? label}) async {
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

  Future<void> updateAccountCredentials(String id, {required String serverUrl, required String token}) async {
    await _accounts.updateCredentials(id, serverUrl: serverUrl, token: token);
    if (id == _accounts.currentId) await connect();
    else _syncAccountState();
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
      msgs.map((m) => (m.isFromMe && m.createdAt == createdAt)
          ? m.copyWith(status: MessageStatus.error) : m).toList();

  List<LocalMessage> _setMessagePending(List<LocalMessage> msgs, int createdAt) =>
      msgs.map((m) => (m.createdAt == createdAt)
          ? m.copyWith(status: MessageStatus.pending) : m).toList();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventSub?.cancel();
    _stateSub?.cancel();
    _connectivitySub?.cancel();
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
```

- [ ] **Step 2: analyze（provider + 其依赖）**

Run: `flutter analyze lib/providers/chat_provider.dart`
Expected: 可能仍因 chat_screen 引用旧 API 报错；仅确认 provider 自身无未定义符号（`JsonDecoder` 已 `import 'dart:convert'`？需补）。补 import：

在 chat_provider.dart 顶部加 `import 'dart:convert';`。

- [ ] **Step 3: 修正 import 后提交**

```bash
git add lib/providers/chat_provider.dart
git commit -m "feat(botapi): 重写 ChatProvider(账户/botapi/事件)"
```

---

## Task 10: AccountEditor 屏幕

**Files:**
- Create: `lib/screens/account_editor_screen.dart`

- [ ] **Step 1: 实现**

```dart
// lib/screens/account_editor_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/chat_provider.dart';
import '../services/account_store.dart';
import '../util/key_mask.dart';

/// 添加 / 编辑账户。add 模式 acc=null；edit 模式传已有账户（token 默认掩码）。
class AccountEditorScreen extends ConsumerStatefulWidget {
  final String? editId; // edit 模式
  final String? initialLabel;
  final String? initialServerUrl;
  final String? initialToken; // edit 时为真实 token
  const AccountEditorScreen({
    super.key, this.editId, this.initialLabel, this.initialServerUrl, this.initialToken,
  });
  @override
  ConsumerState<AccountEditorScreen> createState() => _AccountEditorScreenState();
}

class _AccountEditorScreenState extends ConsumerState<AccountEditorScreen> {
  late final TextEditingController _labelCtrl;
  late final TextEditingController _serverCtrl;
  late final TextEditingController _tokenCtrl;
  bool _revealed = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _labelCtrl = TextEditingController(text: widget.initialLabel ?? '');
    _serverCtrl = TextEditingController(text: widget.initialServerUrl ?? '');
    _tokenCtrl = TextEditingController(text: widget.initialToken ?? '');
  }

  bool get _isEdit => widget.editId != null;

  Future<void> _save() async {
    final server = _serverCtrl.text.trim();
    final token = _tokenCtrl.text.trim();
    if (server.isEmpty || token.isEmpty) {
      setState(() => _error = '服务器地址与 Token 必填');
      return;
    }
    setState(() { _saving = true; _error = null; });
    final notifier = ref.read(chatProvider.notifier);
    bool ok;
    if (_isEdit) {
      await notifier.updateAccountCredentials(widget.editId!,
          serverUrl: server, token: token);
      // 改名（若变了）
      await notifier.renameAccount(widget.editId!, _labelCtrl.text.trim());
      ok = true;
    } else {
      ok = await notifier.addAccount(
          serverUrl: server, token: token, label: _labelCtrl.text.trim());
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() { _saving = false; _error = '已达账户上限(25)'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tokenField = _isEdit && !_revealed && _tokenCtrl.text.isNotEmpty
        ? maskKey(_tokenCtrl.text)
        : _tokenCtrl.text;
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? '编辑账户' : '添加账户')),
      body: SafeArea(child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: _labelCtrl,
            decoration: _dec('名称（可选）'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _serverCtrl,
            keyboardType: TextInputType.url,
            decoration: _dec('服务器地址', hint: 'https://your-host/api/v1/botapi'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tokenCtrl,
            obscureText: !_revealed,
            decoration: _dec('Token', suffix: IconButton(
              icon: Icon(_revealed ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
              onPressed: () => setState(() => _revealed = !_revealed),
            )),
          ),
          if (_isEdit)
            Padding(padding: const EdgeInsets.only(top: 8),
              child: Text(tokenField.isEmpty ? '' : '当前: $tokenField',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
                overflow: TextOverflow.ellipsis)),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_isEdit ? '保存' : '添加', style: const TextStyle(fontSize: 16)),
          ),
        ]),
      )),
    );
  }

  InputDecoration _dec(String label, {String? hint, Widget? suffix}) => InputDecoration(
        labelText: label,
        hintText: hint,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        suffixIcon: suffix,
      );
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/screens/account_editor_screen.dart
git commit -m "feat(botapi): 账户添加/编辑表单"
```

---

## Task 11: AccountDrawer 抽屉

**Files:**
- Create: `lib/widgets/account_drawer.dart`

- [ ] **Step 1: 实现（结构对称 session_drawer）**

```dart
// lib/widgets/account_drawer.dart
//
// 左侧账户选择栏：列表/新建/重命名/编辑凭据/删除。最多 25（上限由 provider 拦截）。
// 风格与聊天页统一：accent 0xFF5B4BD6。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/account.dart';
import '../providers/chat_provider.dart';
import '../screens/account_editor_screen.dart';
import '../services/account_store.dart';

class AccountDrawer extends ConsumerWidget {
  const AccountDrawer({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const accent = Color(0xFF5B4BD6);
    final bg = isDark ? const Color(0xFF151518) : const Color(0xFFFAFAFB);
    final card = isDark ? const Color(0xFF212121) : const Color(0xFFF2F2F6);
    final cardActive = isDark ? const Color(0xFF2A2A45) : const Color(0xFFECE9FB);
    final fg = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final sub = isDark ? const Color(0xFF9E9EA4) : const Color(0xFF8A8A8E);
    final div = isDark ? const Color(0xFF2A2A2E) : const Color(0xFFE5E5EA);

    final accounts = state.accounts;
    final current = state.currentAccountId;

    return Drawer(
      backgroundColor: bg,
      elevation: 0,
      width: 308,
      child: SafeArea(child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
          child: Row(children: [
            Container(
              width: 32, height: 32, alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [accent, Color(0xFF7661D8)]),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.smart_toy_rounded, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 10),
            Text('账户', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: fg)),
            const Spacer(),
            _NewButton(accent: accent, isDark: isDark, fg: fg, onTap: () => _onNew(context, ref)),
          ]),
        ),
        Divider(height: 1, thickness: 0.5, color: div),
        Expanded(
          child: accounts.isEmpty
              ? _Empty(sub: sub)
              : ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: [
                  for (final a in accounts)
                    _AccountTile(
                      name: a.displayName,
                      subtitle: '${_host(a.serverUrl)} · ${_relTime(a.lastUsedAt)}',
                      isCurrent: a.id == current,
                      isDark: isDark, card: card, cardActive: cardActive,
                      fg: fg, sub: sub, accent: accent,
                      onTap: () => _onSelect(context, ref, a.id),
                      onRename: () => _onRename(context, ref, a),
                      onEdit: () => _onEdit(context, a),
                      onDelete: () => _onDelete(context, ref, a),
                    ),
                ]),
        ),
      ])),
    );
  }

  String _host(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url.length > 24 ? '${url.substring(0, 24)}…' : url;
    }
  }

  String _relTime(int ms) {
    final diff = DateTime.now().millisecondsSinceEpoch - ms;
    if (diff < 60000) return '刚刚';
    if (diff < 3600000) return '${diff ~/ 60000}分钟前';
    if (diff < 86400000) return '${diff ~/ 3600000}小时前';
    if (diff < 7 * 86400000) return '${diff ~/ 86400000}天前';
    final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    return '${d.month}-${d.day}';
  }

  void _onNew(BuildContext context, WidgetRef ref) async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => const AccountEditorScreen()));
    if (ok == true && context.mounted) Navigator.of(context).pop();
  }

  void _onSelect(BuildContext context, WidgetRef ref, String id) async {
    Navigator.of(context).pop();
    await ref.read(chatProvider.notifier).selectAccount(id);
  }

  void _onRename(BuildContext context, WidgetRef ref, Account a) {
    final ctrl = TextEditingController(text: a.label ?? a.displayName);
    showDialog<void>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('重命名账户'),
      content: TextField(controller: ctrl, autofocus: true,
        decoration: InputDecoration(border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        TextButton(onPressed: () { Navigator.pop(ctx); ref.read(chatProvider.notifier).renameAccount(a.id, ctrl.text); }, child: const Text('保存')),
      ],
    ));
  }

  void _onEdit(BuildContext context, Account a) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => AccountEditorScreen(
      editId: a.id, initialLabel: a.label, initialServerUrl: a.serverUrl, initialToken: a.token,
    )));
  }

  void _onDelete(BuildContext context, WidgetRef ref, Account a) {
    showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('删除账户'),
      content: Text('确定删除「${a.displayName}」?该账户本地消息将被清除,且无法恢复。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除', style: TextStyle(color: Colors.redAccent))),
      ],
    )).then((confirmed) async {
      if (confirmed == true) {
        if (!context.mounted) return;
        Navigator.of(context).pop();
        await ref.read(chatProvider.notifier).deleteAccount(a.id);
      }
    });
  }
}

class _NewButton extends StatelessWidget {
  final Color accent; final bool isDark; final Color fg; final VoidCallback onTap;
  const _NewButton({required this.accent, required this.isDark, required this.fg, required this.onTap});
  @override
  Widget build(BuildContext context) => Material(
    color: accent, borderRadius: BorderRadius.circular(10),
    child: InkWell(borderRadius: BorderRadius.circular(10), onTap: onTap,
      child: const Padding(padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.add_rounded, color: Colors.white, size: 18),
          SizedBox(width: 2),
          Text('添加', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
        ])),
    ),
  );
}

class _AccountTile extends StatelessWidget {
  final String name, subtitle; final bool isCurrent, isDark;
  final Color card, cardActive, fg, sub, accent;
  final VoidCallback onTap, onRename, onEdit, onDelete;
  const _AccountTile({required this.name, required this.subtitle, required this.isCurrent,
    required this.isDark, required this.card, required this.cardActive, required this.fg,
    required this.sub, required this.accent, required this.onTap,
    required this.onRename, required this.onEdit, required this.onDelete});
  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name.characters.first.toUpperCase() : '?';
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Material(color: isCurrent ? cardActive : card, borderRadius: BorderRadius.circular(14),
        child: InkWell(borderRadius: BorderRadius.circular(14), onTap: onTap,
          child: Padding(padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
            child: Row(children: [
              if (isCurrent) Container(width: 3, height: 30, decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2))),
              if (isCurrent) const SizedBox(width: 8) else const SizedBox(width: 11),
              Container(width: 38, height: 38, alignment: Alignment.center,
                decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(12)),
                child: Text(initial, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700))),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14.5, fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500, color: fg)),
                const SizedBox(height: 2),
                Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: sub)),
              ])),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_horiz, color: sub, size: 20),
                padding: EdgeInsets.zero,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('重命名')),
                  PopupMenuItem(value: 'edit', child: Text('编辑凭据')),
                  PopupMenuItem(value: 'delete', child: Text('删除', style: TextStyle(color: Colors.redAccent))),
                ],
                onSelected: (v) {
                  if (v == 'rename') onRename();
                  if (v == 'edit') onEdit();
                  if (v == 'delete') onDelete();
                },
              ),
            ]))));
  }
}

class _Empty extends StatelessWidget {
  final Color sub;
  const _Empty({required this.sub});
  @override
  Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(32),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.smart_toy_outlined, size: 44, color: sub.withValues(alpha: 0.6)),
      const SizedBox(height: 12),
      Text('暂无账户', style: TextStyle(color: sub, fontSize: 14)),
      const SizedBox(height: 4),
      Text('点击右上角「添加」', style: TextStyle(color: sub.withValues(alpha: 0.7), fontSize: 12)),
    ])));
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/widgets/account_drawer.dart
git commit -m "feat(botapi): 账户选择抽屉"
```

---

## Task 12: SetupScreen（添加首个账户）

**Files:**
- Rewrite: `lib/screens/setup_screen.dart`

- [ ] **Step 1: 重写**

```dart
// lib/screens/setup_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/chat_provider.dart';
import 'chat_screen.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});
  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _labelCtrl = TextEditingController();
  final _serverCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  bool _revealed = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _labelCtrl.dispose(); _serverCtrl.dispose(); _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _onSave() async {
    final server = _serverCtrl.text.trim();
    final token = _tokenCtrl.text.trim();
    if (server.isEmpty || token.isEmpty) {
      setState(() => _error = '服务器地址与 Token 必填');
      return;
    }
    setState(() { _saving = true; _error = null; });
    final ok = await ref.read(chatProvider.notifier).addAccount(
        serverUrl: server, token: token, label: _labelCtrl.text.trim());
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const ChatScreen()));
    } else {
      setState(() { _saving = false; _error = '添加失败（已达上限?）'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Icon(Icons.smart_toy_rounded, size: 56, color: Color(0xFF4A9EFF)),
          const SizedBox(height: 12),
          const Text('欢迎使用 Bot助手', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
          const SizedBox(height: 8),
          const Text('添加一个 botapi 账户即可开始', style: TextStyle(fontSize: 13, color: Colors.grey), textAlign: TextAlign.center),
          const SizedBox(height: 32),
          _field('名称（可选）', _labelCtrl),
          const SizedBox(height: 12),
          _field('服务器地址', _serverCtrl, hint: 'https://your-host/api/v1/botapi'),
          const SizedBox(height: 12),
          _field('Token', _tokenCtrl, obscure: !_revealed, suffix: IconButton(
            icon: Icon(_revealed ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
            onPressed: () => setState(() => _revealed = !_revealed),
          )),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _saving ? null : _onSave,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF4A9EFF),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('开始聊天', style: TextStyle(fontSize: 16)),
          ),
        ]),
      )),
    );
  }

  Widget _field(String label, TextEditingController ctrl, {bool obscure = false, String? hint, Widget? suffix}) =>
      TextField(
        controller: ctrl, obscureText: obscure,
        decoration: InputDecoration(
          labelText: label, hintText: hint, suffixIcon: suffix,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      );
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/screens/setup_screen.dart
git commit -m "feat(botapi): 首启改为添加首个账户"
```

---

## Task 13: SettingsScreen 精简

**Files:**
- Rewrite: `lib/screens/settings_screen.dart`

- [ ] **Step 1: 重写（移除 nickname/apiKey/configId/connectionMode/_ApiKeyTile）**

保留主题、OEM 引导、清理缓存、关于/更新、新增「账户管理」入口（打开抽屉需在 ChatScreen 上下文；此处改为跳转 ChatScreen 并打开抽屉——简化为仅保留主题/缓存/关于/OEM，账户管理由聊天页抽屉承担）。最终决定：设置页保留 主题 / 后台运行设置(OEM) / 清理缓存 / 关于。账户管理不在此页（避免跨页 openDrawer 复杂度）。

```dart
// lib/screens/settings_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../main.dart';
import '../providers/config_provider.dart';
import '../services/config_service.dart';
import '../services/cache_service.dart';
import '../services/update_service.dart';
import '../services/apk_installer.dart';
import '../services/device_oem_service.dart';
import '../util/oem_whitelist.dart';
import '../widgets/oem_whitelist_dialog.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late ConfigService _config;
  String _cacheSize = '计算中...';
  String _currentVersion = '';
  OemWhitelistGuide? _oemGuide;

  @override
  void initState() {
    super.initState();
    _config = ref.read(configServiceProvider);
    _calcCacheSize();
    UpdateService().currentVersion().then((v) {
      if (mounted) setState(() => _currentVersion = v);
    });
    _loadOemGuide();
  }

  Future<void> _loadOemGuide() async {
    final info = await const DeviceOemService().getInfo();
    if (!mounted) return;
    final guide = whitelistGuideFor(info);
    if (guide.needsGuide) setState(() => _oemGuide = guide);
  }

  void _showOemGuide() {
    final guide = _oemGuide;
    if (guide == null || !guide.needsGuide) return;
    showDialog<void>(context: context, builder: (_) => OemWhitelistDialog(guide: guide));
  }

  Future<void> _calcCacheSize() async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${dir.path}/attachments');
    int total = 0;
    if (await cacheDir.exists()) {
      await for (final e in cacheDir.list()) {
        if (e is File) total += await e.length();
      }
    }
    if (mounted) {
      setState(() {
        _cacheSize = total > 1024 * 1024
            ? '${(total / 1024 / 1024).toStringAsFixed(1)} MB'
            : '${(total / 1024).toStringAsFixed(0)} KB';
      });
    }
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理缓存'),
        content: Text('当前缓存: $_cacheSize，确定清理？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清理')),
        ],
      ),
    );
    if (confirmed == true) {
      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${dir.path}/attachments');
      if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
      final cacheService = CacheService();
      await cacheService.clearAll();
      if (mounted) {
        setState(() => _cacheSize = '0 KB');
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('缓存已清理')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(children: [
        Consumer(builder: (context, ref, _) {
          final currentMode = ref.watch(themeModeProvider);
          return ListTile(
            title: const Text('主题模式'),
            subtitle: Text(currentMode == ThemeMode.light ? '白天' : currentMode == ThemeMode.dark ? '夜间' : '跟随系统'),
            trailing: DropdownButton<ThemeMode>(
              value: currentMode, underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: ThemeMode.system, child: Text('自动')),
                DropdownMenuItem(value: ThemeMode.light, child: Text('白天')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('夜间')),
              ],
              onChanged: (v) async {
                if (v != null) {
                  await _config.setThemeMode(v);
                  ref.read(themeModeProvider.notifier).state = v;
                }
              },
            ),
          );
        }),
        if (_oemGuide != null && _oemGuide!.needsGuide)
          ListTile(
            leading: Icon(Icons.bolt_rounded, color: Theme.of(context).colorScheme.primary, size: 22),
            title: const Text('后台运行设置'),
            subtitle: Text(_oemGuide!.reason, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, height: 1.3)),
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: _showOemGuide,
          ),
        const Divider(),
        ListTile(
          title: const Text('清理缓存'),
          subtitle: Text('当前: $_cacheSize'),
          onTap: _clearCache,
        ),
        ListTile(
          title: const Text('关于'),
          subtitle: Text(_currentVersion.isEmpty ? '检查更新' : 'Bot助手 v$_currentVersion · 点击检查更新'),
          onTap: () => showDialog<void>(context: context, builder: (_) => const _UpdateDialog()),
        ),
      ]),
    );
  }
}

/// 检查更新对话框（沿用既有实现，保持不变）
class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog();
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  final UpdateService _svc = UpdateService();
  _S _s = _S.checking;
  UpdateCheck? _check;
  double _progress = 0;

  @override
  void initState() { super.initState(); _doCheck(); }

  Future<void> _doCheck() async {
    setState(() => _s = _S.checking);
    final c = await _svc.check();
    if (!mounted) return;
    _check = c;
    setState(() {
      if (c.error != null) _s = _S.error;
      else if (c.hasUpdate) _s = _S.available;
      else _s = _S.latest;
    });
  }

  Future<void> _downloadAndInstall() async {
    final info = _check?.latest;
    if (info == null) return;
    setState(() { _s = _S.downloading; _progress = 0; });
    try {
      final path = await _svc.download(info.apkUrl, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() => _s = _S.installing);
      await ApkInstaller.install(path);
    } catch (e) {
      if (mounted) {
        _check = UpdateCheck(currentVersion: _check?.currentVersion ?? '', error: '更新失败: $e');
        setState(() => _s = _S.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _check?.latest;
    final title = switch (_s) {
      _S.checking => '检查更新',
      _S.available => '发现新版本 ${info?.tag ?? ''}',
      _S.latest => '已是最新版本',
      _S.error => '检查更新',
      _S.downloading => '正在下载',
      _S.installing => '正在安装',
    };
    final actions = <Widget>[
      if (_s == _S.error) TextButton(onPressed: _doCheck, child: const Text('重试')),
      if (_s == _S.available) ...[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('以后再说')),
        FilledButton(onPressed: _downloadAndInstall, child: const Text('立即更新')),
      ],
      if (_s == _S.latest || _s == _S.error)
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
    ];
    return AlertDialog(
      title: Text(title),
      content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 320), child: _content(info)),
      actions: actions,
    );
  }

  Widget _content(UpdateInfo? info) {
    switch (_s) {
      case _S.checking:
        return const Row(children: [
          SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 16),
          Text('正在检查最新版本...'),
        ]);
      case _S.available:
        final notes = (info?.notes.trim().isNotEmpty == true) ? info!.notes.trim() : '修复与改进。';
        return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (info!.sizeLabel.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 8),
              child: Text('大小:${info.sizeLabel}  当前:v${_check!.currentVersion}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey))),
          Text(notes, style: const TextStyle(fontSize: 13, height: 1.4)),
        ]));
      case _S.latest:
        return Text('当前已是最新版本 v${_check?.currentVersion ?? ""}。');
      case _S.error:
        return Text(_check?.error ?? '检查失败,请稍后重试。');
      case _S.downloading:
        final pct = (_progress * 100).round();
        return Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(value: _progress > 0 ? _progress : null),
          const SizedBox(height: 10),
          Text('$pct%', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ]);
      case _S.installing:
        return const Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(height: 12),
          Text('下载完成,请在系统弹出的安装界面确认安装。', style: TextStyle(fontSize: 13, height: 1.4)),
        ]);
    }
  }
}

enum _S { checking, available, latest, error, downloading, installing }
```

- [ ] **Step 2: 提交**

```bash
git add lib/screens/settings_screen.dart
git commit -m "feat(botapi): 精简设置页(删 webchat 凭据/连接模式)"
```

---

## Task 14: ChatScreen 改造

**Files:**
- Modify: `lib/screens/chat_screen.dart`

> 局部编辑：drawer、Bar 标题、媒体发送/下载走 provider、思考气泡、needsRebuild 字段重命名。

- [ ] **Step 1: import 替换**

把 `import '../widgets/session_drawer.dart';` 改为 `import '../widgets/account_drawer.dart';`。
把 `import '../models/chat_event.dart';` 改为 `import '../models/botapi_event.dart';`。
移除 `import '../services/file_service.dart';`（不再直接用）。

- [ ] **Step 2: drawer 替换**

`drawer: const SessionDrawer(),` → `drawer: const AccountDrawer(),`

- [ ] **Step 3: needsRebuild 字段重命名**

在 `ref.listen` 的 `needsRebuild` 判定中：
`n.currentSessionName != _state.currentSessionName` → `n.currentAccountName != _state.currentAccountName`。
`_state.currentSessionName` 所有引用 → `_state.currentAccountName`。
`_Bar(sessionName: _state.currentSessionName, ...)` → `_Bar(accountName: _state.currentAccountName, ...)`。

- [ ] **Step 4: 流式思考气泡**

在 `_item(int i)` 中，`int j = i - msgs.length;` 之后、`if (j < _state.toolCalls.length)` 段删除（不再有 toolCalls/toolResults）。改为：先渲染 `toolStatuses`，再渲染 `streamingThinking`（可折叠），再渲染 `streamingText`。

替换 `_itemCount` 与 `_item`：

```dart
int _itemCount() => _state.messages.length +
    _state.toolStatuses.length +
    ((_state.streamingThinking?.isNotEmpty == true) ? 1 : 0) +
    ((_state.streamingText?.isNotEmpty == true) ? 1 : 0);

Widget _item(int i) {
  final msgs = _state.messages;
  if (i < msgs.length) {
    final m = msgs[i];
    final curDay = _dayKey(m.createdAt);
    final prevDay = i == 0 ? null : _dayKey(msgs[i - 1].createdAt);
    final showDate = prevDay != curDay;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (showDate) _DateDivider(label: _dateLabel(m.createdAt), isDark: _isDark),
      _Bubble(m: m, bw: _w - 48, isDark: _isDark),
    ]);
  }
  int j = i - msgs.length;
  if (j < _state.toolStatuses.length) {
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 2),
      child: _ToolStatus(text: _state.toolStatuses[j]));
  }
  j -= _state.toolStatuses.length;
  if (j == 0 && _state.streamingThinking?.isNotEmpty == true) {
    return _ThinkingBlock(text: _state.streamingThinking!, isDark: _isDark);
  }
  return Consumer(builder: (ctx, ref, _) {
    final st = ref.watch(chatProvider.select((s) => s.streamingText)) ?? '';
    return _Streaming(text: st, bw: _w - 48, isDark: _isDark);
  });
}
```

新增 widget：

```dart
class _ToolStatus extends StatelessWidget {
  final String text;
  const _ToolStatus({required this.text});
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(color: const Color(0xFF007AFF).withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
    padding: const EdgeInsets.all(8),
    child: Text(text, style: const TextStyle(color: Color(0xFF007AFF), fontSize: 12, fontFamily: 'monospace')));
}

class _ThinkingBlock extends StatefulWidget {
  final String text; final bool isDark;
  const _ThinkingBlock({required this.text, required this.isDark});
  @override State<_ThinkingBlock> createState() => _ThinkingBlockState();
}
class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _open = false;
  @override
  Widget build(BuildContext context) {
    final fg = widget.isDark ? const Color(0xFF9E9EA4) : const Color(0xFF8A8A8E);
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 2),
      child: Container(
        decoration: BoxDecoration(color: fg.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
        child: Column(children: [
          InkWell(onTap: () => setState(() => _open = !_open),
            child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [
              const Icon(Icons.psychology_outlined, size: 14, color: Color(0xFF8A8A8E)),
              const SizedBox(width: 6),
              Expanded(child: Text('思考过程', style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w500))),
              AnimatedRotation(turns: _open ? 0.5 : 0, duration: const Duration(milliseconds: 150),
                child: Icon(Icons.expand_more, color: fg, size: 16)),
            ]))),
          if (_open) Container(width: double.infinity, padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text(widget.text, style: TextStyle(color: fg, fontSize: 11, height: 1.3, fontFamily: 'monospace'))),
        ])));
  }
}
```

删除 `_ToolMsg` / `_ToolResult` / `_Inline` / `_InlineState`（不再用）。

- [ ] **Step 5: 媒体发送改走 provider（不经 FileService）**

`_endVoice` / `_sendImage` / `_sendFile` 中：
```dart
final config = ref.read(configServiceProvider);
final fs = FileService(serverUrl: config.serverUrl, apiKey: config.apiKey);
final result = await fs.uploadFile(...);
final id = result['attachment_id'] as String?;
```
改为经 provider 暴露的上传方法。在 ChatNotifier 增加（Task 9 已有 `retryMediaSend` 用 `BotApiHttp.uploadFile`，但发送流程需要 provider 提供 `uploadMedia`）。在 chat_provider.dart 增加公共方法：

```dart
/// 上传媒体文件，返回 file_id 或 null。内部用当前账户的 BotApiHttp。
Future<String?> uploadMedia(File file, String mime, {void Function(int, int)? onProgress}) async {
  final acc = _currentAccount;
  if (acc == null) return null;
  final http = _http ?? BotApiHttp(serverUrl: acc.serverUrl, token: acc.token);
  final r = await http.uploadFile(file, mime, onProgress: onProgress);
  return r?.fileId;
}
```

UI 三处改为：
```dart
final id = await ref.read(chatProvider.notifier).uploadMedia(file, mime,
    onProgress: (s, t) => ref.read(chatProvider.notifier).updateUploadProgress(key, t > 0 ? s / t : 0));
if (id != null && mounted) {
  ref.read(chatProvider.notifier).finalizeMediaSend(key, id, msgType);
} else if (mounted) {
  ref.read(chatProvider.notifier).failMediaUpload(key);
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$name 上传失败'), backgroundColor: Colors.redAccent));
}
```

（各处的 SnackBar 文案按 image/voice/file 调整。）

- [ ] **Step 6: 媒体气泡下载逻辑简化**

`_ImageBubble` / `_VoiceBubble` / `_FileBubble`：botapi 收到的媒体在 provider 收到事件时已下载到 `localPath`。UI 仅读 `localPath`：若 `localPath` 非空直接用；为空（仍在下载）显示 loading。移除 `downloadAttachment(aid)` 分支。

`_ImageBubbleState._download` 改为：
```dart
// 不再主动下载；provider 已下载到 localPath。仅等待 widget 更新（didUpdateWidget）。
```
即：`initState` 中若 `localPath` 非空则用，否则等 `didUpdateWidget` 带 localPath 来。删除 `FileService` 下载调用。

`_FileBubble._open`：优先 `localPath`（provider 下载的），否则无（不可下载，因 URL 已失效）。简化为用 `localPath`。

- [ ] **Step 7: `_Bar` 改名 sessionName→accountName**

`_Bar` 字段 `final String sessionName;` → `final String accountName;`；构造参数同名；`Text(sessionName,...)` → `Text(accountName,...)`。

- [ ] **Step 8: analyze**

Run: `flutter analyze lib/screens/chat_screen.dart`
Expected: No issues（依赖 provider 的新方法已就绪）

- [ ] **Step 9: 提交**

```bash
git add lib/screens/chat_screen.dart lib/providers/chat_provider.dart
git commit -m "feat(botapi): 聊天页接入账户抽屉/思考气泡/媒体走 provider"
```

---

## Task 15: main.dart + config_provider

**Files:**
- Modify: `lib/main.dart`
- Modify: `lib/providers/config_provider.dart`

- [ ] **Step 1: main.dart 清理**

`main()` 中 `Future.microtask` 的启动清理改用 `BotApiHttp.cleanOldCache`：

```dart
import 'services/botapi_http.dart';
...
Future.microtask(() async {
  try {
    await BotApiHttp.cleanOldCache();
  } catch (_) {}
});
```
移除 `import 'services/file_service.dart';` 与对 `FileService`/`cleaner.serverUrl` 的使用。

- [ ] **Step 2: config_provider 不变（isConfigured 仍由 config 返回）**

`configInitializedProvider` 返回 `service.isConfigured`（迁移后为 false → 进 SetupScreen；添加账户后 setConfigured(true)）。无需改动。

- [ ] **Step 3: 提交**

```bash
git add lib/main.dart
git commit -m "feat(botapi): 启动清理改用 BotApiHttp.cleanOldCache"
```

---

## Task 16: 删除旧文件

**Files:**
- Delete: 见下

- [ ] **Step 1: 删除**

```bash
git rm lib/services/astrbot_sse_client.dart \
       lib/services/astrbot_ws_client.dart \
       lib/models/chat_session.dart \
       lib/services/session_store.dart \
       lib/services/prefs_storage.dart \
       lib/widgets/session_drawer.dart \
       lib/models/chat_event.dart \
       test/session_store_test.dart
```

- [ ] **Step 2: 检查无残留引用**

Run: `grep -rn "astrbot_sse_client\|astrbot_ws_client\|chat_session\|session_store\|prefs_storage\|session_drawer\|chat_event" lib/ test/ || true`
Expected: 无输出（或仅注释/无关）

- [ ] **Step 3: 提交**

```bash
git commit -m "chore(botapi): 删除 webchat 客户端/会话/事件旧文件"
```

---

## Task 17: analyze + 全量测试 + 构建验证 + 版本号

**Files:**
- Modify: `android/app/build.gradle.kts`

- [ ] **Step 1: 全量 analyze**

Run: `flutter analyze`
Expected: No issues found（修掉所有残留引用错误）

- [ ] **Step 2: 全量测试**

Run: `flutter test`
Expected: All tests passed

- [ ] **Step 3: 版本号**

`android/app/build.gradle.kts`：`versionCode = 11` → `12`；`versionName = "1.1.9"` → `"1.2.0"`。

- [ ] **Step 4: 构建 APK**

Run: `flutter build apk --release`
Expected: build 成功，输出 APK 路径

- [ ] **Step 5: 提交**

```bash
git add android/app/build.gradle.kts
git commit -m "chore(botapi): 版本号 1.2.0(12)"
```

---

## Task 18: 真机集成验证（ADB）

> ADB 设备已就绪。

- [ ] **Step 1: 安装到设备**

Run: `adb install -r build/app/outputs/flutter-apk/app-release.apk`
Expected: Success

- [ ] **Step 2: 启动并添加真实账户**

- 启动 app → setup 页 → 填名称/服务器地址/真实 botapi token → 开始聊天 → 进入聊天页。
- 验证：AppBar 显示账户名；抽屉列出账户。

- [ ] **Step 3: 收发文本 + 流式**

- 发「你好」→ 收到流式回复 → final 自纠正 → 落库。
- 切后台再回前台 → history 合并补漏，消息不丢。

- [ ] **Step 4: 媒体**

- 发图片/语音/文件 → 上传 → 对方收到 → 下载渲染。
- 自动播放语音开关。

- [ ] **Step 5: 多账户**

- 抽屉添加第二个账户 → 切换 → 各自历史独立。

- [ ] **Step 6: 设置页**

- 主题切换、清理缓存、关于/更新、OEM 引导（若机型需要）。

- [ ] **Step 7: 提交验证记录**

无需代码改动；如发现问题，回到对应 Task 修复。

---

## Self-Review

**1. Spec coverage:**
- 迁移 botapi 接口：Task 4/5/9 ✓
- 多会话→多账户：Task 3/9/11 ✓
- 删除 nickname/apiKey/configId/连接模式：Task 8/13 ✓
- 保留 UI 风格/媒体/流式/自动播放/前台保活/OEM/主题/更新：Task 11/13/14 + 前台服务未动 ✓
- D5 历史补全：Task 7(mergeHistory) + Task 9(connect 流程) ✓
- D6 DB v6 server_id：Task 6/7 ✓
- D7 thinking：Task 9(_handleEvent) + Task 14(_ThinkingBlock) ✓
- D8 token 掩码：Task 10/12（key_mask 复用）✓
- D9 /auth 校验：Task 9 ✓
- 干净迁移 v3：Task 8 ✓

**2. Placeholder scan:** 无 TBD/TODO；所有代码步骤含完整代码。

**3. Type consistency:**
- `Account.displayName` / `AccountStore.add/select/rename/updateCredentials/delete/touchCurrent/currentId/accounts` 跨任务一致 ✓
- `BotApiEvent.fromSse/isPing/isError/isThinking/isMessage/isToolStatus/isFinalText/isStreamingText/isMedia` 一致 ✓
- `BotApiHttp.auth/sendMessage/uploadFile/fetchHistory/downloadByUrl` + `UploadResult` + `HistoryResult`/`HistoryRow` 一致 ✓
- `BotApiClient.connect(sinceCursor:)`/`events`/`state` 一致 ✓
- `CacheService.mergeHistory(rows, accountId)`/`maxServerId(accountId)`/`wipeIfFlagged(prefs)` 一致 ✓
- `ChatState.currentAccountId/currentAccountName/accounts/streamingThinking/toolStatuses` 与 UI 引用一致 ✓
- `ChatNotifier.addAccount/selectAccount/renameAccount/updateAccountCredentials/deleteAccount/uploadMedia` 与 UI/Setup/Drawer 调用一致 ✓
- `kNoAccount` 常量定义于 account_store.dart，provider/UI 共用 ✓

**注意点（执行时留意）：**
- Task 9 `_handleMedia` 用 `_decode`/`_jsonDecoder` 需 `import 'dart:convert'`（已在 Step 2 注明补 import）。
- Task 9 `_dispatchPending` 中 `failed` 列表逻辑：简化为不区分失败（botapi sendMessage 返回 Future，drain 时直接重发，失败的由 then 标 error）。当前实现 `failed` 永远为空——可接受（pending 仅在未连接时累积，drain 时已 connected）。保持现状。
- Task 14 媒体气泡下载简化后，`_ImageBubble` 的 `didUpdateWidget` 仍需保留以接收 localPath 更新。
- `flutter_foreground_task`、`audio_service`、`play_queue` 等未触及，保持原样。
