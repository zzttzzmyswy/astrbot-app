// test/cache_service_dup_test.dart
//
// 验证「bot 回复后两条一模一样消息」的修复：
// 1. mergeHistory 的 live-link 去掉单向时间窗,服务端时钟超前也不再插入重复行;
// 2. upsertBotText 返回是否真正插入,调用方据此不入内存列表,内存与 DB 一致。
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:astrbot_app/services/cache_service.dart';
import 'package:astrbot_app/models/message.dart';
import 'package:astrbot_app/models/history_row.dart';

LocalMessage _botText(String content, int createdAt) => LocalMessage(
      msgType: 'text',
      content: content,
      isFromMe: false,
      status: MessageStatus.sent,
      createdAt: createdAt,
    );

int _dbCounter = 0;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() {
    // 每用例独立文件 DB,且先删旧文件（inMemoryDatabasePath 在 ffi 下跨 open 共享;
    // 文件名 counter 每进程重置,跨运行会复用同名文件造成污染）。
    final p = '${Directory.systemTemp.path}/astrbot_dup_${_dbCounter++}.db';
    final f = File(p);
    if (f.existsSync()) f.deleteSync();
    CacheService.dbPathOverride = p;
    CacheService.resetDbForTesting();
  });
  tearDown(() async {
    // 关闭静态 DB 句柄,避免下个用例/下个文件复用旧连接。
    await CacheService().close();
  });

  group('upsertBotText 返回是否插入', () {
    test('首次插入 true,重复 false', () async {
      final cache = CacheService();
      final t = 1700000000000;
      expect(await cache.upsertBotText(_botText('答案', t), accountId: 'a'), isTrue);
      expect(await cache.upsertBotText(_botText('答案', t + 1000), accountId: 'a'), isFalse);
      expect((await cache.getMessages(accountId: 'a')).length, 1);
    });
  });

  group('final 实时行 vs 历史行 去重', () {
    test('时钟同步：live-link 命中,1 条', () async {
      final cache = CacheService();
      const acc = 'a';
      await cache.upsertBotText(_botText('答案', 1700000000000), accountId: acc);
      await cache.mergeHistory([
        HistoryRow(messageId: 101, role: 'assistant', type: 'text', content: '答案', timestamp: 1700000000)
      ], accountId: acc);
      expect((await cache.getMessages(accountId: acc)).length, 1);
    });

    test('服务端时钟超前 10 分钟：live-link 仍命中(去时间窗后),不重复', () async {
      final cache = CacheService();
      const acc = 'a';
      await cache.upsertBotText(_botText('答案', 1700000000000), accountId: acc);
      await cache.mergeHistory([
        HistoryRow(messageId: 101, role: 'assistant', type: 'text', content: '答案', timestamp: 1700000000 + 600)
      ], accountId: acc);
      final msgs = await cache.getMessages(accountId: acc);
      expect(msgs.length, 1, reason: '去时间窗后按内容+角色匹配,时钟偏差不再插重复行');
      expect(msgs.first.serverId, 101); // 实时行被 link 贴上 server_id
    });

    test('内容不同：各自独立行', () async {
      final cache = CacheService();
      const acc = 'a';
      await cache.upsertBotText(_botText('答案一', 1700000000000), accountId: acc);
      await cache.mergeHistory([
        HistoryRow(messageId: 101, role: 'assistant', type: 'text', content: '答案二', timestamp: 1700000000)
      ], accountId: acc);
      expect((await cache.getMessages(accountId: acc)).length, 2);
    });
  });

  group('双 commit(模拟 final 重复处理) 内存与 DB 一致', () {
    test('第二次 upsertBotText 返回 false,调用方不入列 → 仅 1 条', () async {
      final cache = CacheService();
      const acc = 'a';
      final t = 1700000000000;
      // 第一次 commit:插入,入列
      final i1 = await cache.upsertBotText(_botText('答案', t), accountId: acc);
      final list = <LocalMessage>[];
      if (i1) list.add(_botText('答案', t));
      // 第二次 commit(重复):DB 去重,不入列
      final i2 = await cache.upsertBotText(_botText('答案', t + 500), accountId: acc);
      if (i2) list.add(_botText('答案', t + 500));
      expect(list.length, 1, reason: '内存列表与 DB 去重一致,无双行');
      expect((await cache.getMessages(accountId: acc)).length, 1);
    });
  });
}
