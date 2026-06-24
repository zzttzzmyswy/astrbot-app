// test/account_store_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/services/account_store.dart';

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
    final a = (await s.add(serverUrl: 'https://h', token: 't1', label: '工作'))!;
    expect(s.currentId, a.id);
    expect(s.accounts.first.displayName, '工作');
    expect(a.token, 't1');
  });

  test('无 label 时 displayName 派生', () async {
    final a = (await s.add(serverUrl: 'https://h', token: 't1'))!;
    expect(a.displayName, 'Bot ${a.id.substring(0, 4)}');
  });

  test('25 上限：第 26 个 add 返回 null', () async {
    for (int i = 0; i < 25; i++) {
      await s.add(serverUrl: 'h', token: 't$i');
    }
    expect(await s.add(serverUrl: 'h', token: 't25'), isNull);
  });

  test('add 多个同毫秒 id 不碰撞', () async {
    final ids = <String>{};
    for (int i = 0; i < 50; i++) {
      final a = await s.add(serverUrl: 'h', token: 't$i');
      if (a != null) ids.add(a.id);
    }
    expect(ids.length, 25); // 上限
  });

  test('select 切换 + touchCurrent 排序', () async {
    final a = (await s.add(serverUrl: 'h', token: 't1'))!;
    final b = (await s.add(serverUrl: 'h', token: 't2'))!;
    await s.select(a.id);
    expect(s.currentId, a.id);
    // touch 必须用大于 b.lastUsedAt 的时间戳,a 才会排到最前(b 是刚 add 的,时间戳≈now)。
    await s.touchCurrent(nowMs: DateTime.now().millisecondsSinceEpoch + 100000);
    expect(s.accounts.first.id, a.id);
    expect(s.accounts.any((x) => x.id == b.id), true);
  });

  test('updateCredentials 改 serverUrl/token', () async {
    final a = (await s.add(serverUrl: 'h', token: 't1'))!;
    final ok = await s.updateCredentials(a.id, serverUrl: 'h2', token: 't2');
    expect(ok, true);
    expect(s.accounts.first.serverUrl, 'h2');
    expect(s.accounts.first.token, 't2');
  });

  test('rename', () async {
    final a = (await s.add(serverUrl: 'h', token: 't1'))!;
    await s.rename(a.id, '新名');
    expect(s.accounts.first.displayName, '新名');
  });

  test('rename 空串清除 label', () async {
    final a = (await s.add(serverUrl: 'h', token: 't1', label: 'x'))!;
    await s.rename(a.id, '  ');
    expect(s.accounts.first.label, isNull);
  });

  test('delete 当前账户 → 切到另一个', () async {
    final a = (await s.add(serverUrl: 'h', token: 't1'))!;
    final b = (await s.add(serverUrl: 'h', token: 't2'))!;
    String deleted = '';
    await s.delete(b.id, deleteMessages: (_) async { deleted = b.id; });
    expect(deleted, b.id);
    expect(s.currentId, a.id);
  });

  test('delete 非当前账户仅刷新列表', () async {
    final a = (await s.add(serverUrl: 'h', token: 't1'))!;
    final b = (await s.add(serverUrl: 'h', token: 't2'))!;
    await s.select(a.id);
    await s.delete(b.id, deleteMessages: (_) async {});
    expect(s.currentId, a.id);
    expect(s.accounts.length, 1);
  });

  test('delete 唯一账户 → 占位', () async {
    final a = (await s.add(serverUrl: 'h', token: 't1'))!;
    await s.delete(a.id, deleteMessages: (_) async {});
    expect(s.currentId, kNoAccount);
    expect(s.accounts, isEmpty);
  });

  test('持久化：重 load 后列表与 current 一致', () async {
    final mem = _Mem();
    final s1 = AccountStore(mem);
    await s1.load();
    final a = (await s1.add(serverUrl: 'h', token: 't1', label: 'L'))!;
    final s2 = AccountStore(mem);
    await s2.load();
    expect(s2.accounts.length, 1);
    expect(s2.currentId, a.id);
    expect(s2.accounts.first.label, 'L');
  });
}
