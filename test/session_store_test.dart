// test/session_store_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/models/chat_session.dart';
import 'package:astrbot_app/services/session_store.dart';

/// 内存 SessionStorage,用于单测(绕过 SharedPreferences 平台绑定)。
class _MemStorage implements SessionStorage {
  final Map<String, String> _m = {};
  @override
  Future<String?> readString(String key) async => _m[key];
  @override
  Future<void> writeString(String key, String value) async => _m[key] = value;
}

Future<SessionStore> _fresh() async {
  final s = SessionStore(_MemStorage());
  await s.load();
  return s;
}

void main() {
  group('ChatSession', () {
    test('serde 往返', () {
      final s = ChatSession(id: 'abc123', createdAt: 100, lastUsedAt: 200, name: '工作');
      final j = s.toJson();
      final back = ChatSession.fromJson(j);
      expect(back.id, 'abc123');
      expect(back.name, '工作');
      expect(back.createdAt, 100);
      expect(back.lastUsedAt, 200);
    });

    test('name 为 null 时不序列化 name 字段', () {
      final s = ChatSession(id: 'x', createdAt: 1, lastUsedAt: 2);
      expect(s.toJson().containsKey('name'), isFalse);
    });

    test('displayName 优先 name,否则派生 id 前 8 位', () {
      expect(ChatSession(id: 'abcdefgh1234', createdAt: 0, lastUsedAt: 0).displayName, 'abcdefgh');
      expect(
          ChatSession(id: 'abcdefgh1234', createdAt: 0, lastUsedAt: 0, name: '我的会话').displayName,
          '我的会话');
    });

    test('derivedName 短 id 原样返回', () {
      expect(ChatSession.derivedName('ab'), 'ab');
    });
  });

  group('SessionStore load/seed', () {
    test('空注册表 + 无旧 session_id → 当前为占位', () async {
      final s = await _fresh();
      await s.seedFromLegacy(legacySessionId: null);
      expect(s.sessions, isEmpty);
      expect(s.currentId, kPendingSessionId);
    });

    test('空注册表 + 有旧 session_id → 种一条, currentId 指向它', () async {
      final s = await _fresh();
      await s.seedFromLegacy(legacySessionId: 'legacy-uuid-1');
      expect(s.sessions.length, 1);
      expect(s.sessions.first.id, 'legacy-uuid-1');
      expect(s.currentId, 'legacy-uuid-1');
    });

    test('已有注册表不被 seed 覆盖', () async {
      final storage = _MemStorage();
      // 预置一条会话
      final s1 = SessionStore(storage);
      await s1.load();
      await s1.registerServerSession('exist-1', nowMs: 100);
      // 再 seed:不应覆盖
      final s2 = SessionStore(storage);
      await s2.load();
      await s2.seedFromLegacy(legacySessionId: 'legacy-uuid-1');
      expect(s2.sessions.length, 1);
      expect(s2.sessions.first.id, 'exist-1');
    });

    test('持久化后重载,数据保留', () async {
      final storage = _MemStorage();
      final s1 = SessionStore(storage);
      await s1.load();
      await s1.seedFromLegacy(legacySessionId: 's1');
      await s1.registerServerSession('s2', nowMs: 50);
      await s1.registerServerSession('s3', nowMs: 90);

      final s2 = SessionStore(storage);
      await s2.load();
      expect(s2.sessions.map((e) => e.id).toSet(), {'s1', 's2', 's3'});
      expect(s2.currentId, 's3'); // 最后注册的
    });
  });

  group('SessionStore CRUD', () {
    test('beginNew 切到占位', () async {
      final s = await _fresh();
      await s.registerServerSession('a', nowMs: 10);
      expect(s.currentId, 'a');
      expect(await s.beginNew(), true);
      expect(s.currentId, kPendingSessionId);
    });

    test('registerServerSession 同 id 复用:不新增,只更新 lastUsedAt', () async {
      final s = await _fresh();
      await s.registerServerSession('a', nowMs: 10);
      await s.registerServerSession('a', nowMs: 99);
      expect(s.sessions.length, 1);
      expect(s.sessions.first.lastUsedAt, 99);
    });

    test('select 切换 + 触摸 lastUsedAt,不存在返回 false', () async {
      final s = await _fresh();
      await s.registerServerSession('a', nowMs: 10);
      await s.registerServerSession('b', nowMs: 20);
      expect(await s.select('a'), true);
      expect(s.currentId, 'a');
      expect(await s.select('zzz'), false);
    });

    test('rename 改名,不存在返回 false', () async {
      final s = await _fresh();
      await s.registerServerSession('a', nowMs: 10);
      expect(await s.rename('a', '工作'), true);
      expect(s.sessions.firstWhere((e) => e.id == 'a').name, '工作');
      // 空名 → 回退为 null(派生名)
      expect(await s.rename('a', '   '), true);
      expect(s.sessions.firstWhere((e) => e.id == 'a').name, isNull);
      expect(await s.rename('zzz', 'x'), false);
    });

    test('delete 删非当前会话:不动 currentId', () async {
      final s = await _fresh();
      await s.registerServerSession('a', nowMs: 10);
      await s.registerServerSession('b', nowMs: 20);
      await s.select('a');
      final deleted = <String>[];
      final next = await s.delete('b', deleteMessages: (id) async => deleted.add(id));
      expect(deleted, ['b']);
      expect(s.sessions.any((e) => e.id == 'b'), isFalse);
      expect(next, 'a');
      expect(s.currentId, 'a');
    });

    test('delete 删当前会话:切到最近的另一个', () async {
      final s = await _fresh();
      await s.registerServerSession('a', nowMs: 10);
      await s.registerServerSession('b', nowMs: 20);
      await s.select('a'); // current = a
      final next = await s.delete('a', deleteMessages: (_) async {});
      expect(next, 'b');
      expect(s.currentId, 'b');
    });

    test('delete 删最后一个会话:切到占位', () async {
      final s = await _fresh();
      await s.registerServerSession('a', nowMs: 10);
      final next = await s.delete('a', deleteMessages: (_) async {});
      expect(next, kPendingSessionId);
      expect(s.currentId, kPendingSessionId);
    });

    test('排序:按 lastUsedAt 降序', () async {
      final s = await _fresh();
      await s.registerServerSession('old', nowMs: 5);
      await s.registerServerSession('new', nowMs: 90);
      await s.registerServerSession('mid', nowMs: 50);
      expect(s.sessions.map((e) => e.id).toList(), ['new', 'mid', 'old']);
    });
  });

  group('SessionStore 25 上限', () {
    test('达 25 上限时 beginNew 返回 false', () async {
      final s = await _fresh();
      for (int i = 0; i < kMaxSessions; i++) {
        await s.registerServerSession('s$i', nowMs: i);
      }
      expect(s.sessions.length, kMaxSessions);
      // 切到一个真实会话后再 beginNew:应被拒
      await s.select('s0');
      expect(await s.beginNew(), false);
      // currentId 不变(未被切到占位)
      expect(s.currentId, 's0');
    });

    test('未达上限 beginNew 成功', () async {
      final s = await _fresh();
      for (int i = 0; i < kMaxSessions - 1; i++) {
        await s.registerServerSession('s$i', nowMs: i);
      }
      expect(await s.beginNew(), true);
    });
  });

  group('SessionStore touchCurrent', () {
    test('触摸当前会话更新 lastUsedAt 并重排', () async {
      final s = await _fresh();
      await s.registerServerSession('a', nowMs: 100);
      await s.registerServerSession('b', nowMs: 50); // a 在前
      expect(s.sessions.first.id, 'a');
      await s.select('b'); // b now=最新
      expect(s.sessions.first.id, 'b');
    });

    test('占位 currentId 时 touchCurrent 无副作用', () async {
      final s = await _fresh();
      await s.beginNew();
      await s.touchCurrent(nowMs: 999);
      expect(s.sessions, isEmpty);
      expect(s.currentId, kPendingSessionId);
    });
  });
}
