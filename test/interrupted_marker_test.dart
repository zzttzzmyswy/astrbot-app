// test/interrupted_marker_test.dart
//
// 验证「熄屏假中断 → 中断占位行 + 完整回复并存」的修复:
// - interrupted_marker 纯函数:占位识别、去后缀、前缀覆盖判定。
// - CacheService.reconcileInterruptedPlaceholders:被完整回复覆盖的占位行清除,
//   无覆盖(真断连)则保留;mergeHistory 末尾自动调用。
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:astrbot_app/services/cache_service.dart';
import 'package:astrbot_app/models/message.dart';
import 'package:astrbot_app/models/history_row.dart';
import 'package:astrbot_app/util/interrupted_marker.dart';

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
    final p = '${Directory.systemTemp.path}/astrbot_intr_${_dbCounter++}.db';
    final f = File(p);
    if (f.existsSync()) f.deleteSync();
    CacheService.dbPathOverride = p;
    CacheService.resetDbForTesting();
  });
  tearDown(() async {
    await CacheService().close();
  });

  group('interrupted_marker 纯函数', () {
    test('isInterruptedPlaceholder: 仅后缀结尾为占位行', () {
      expect(isInterruptedPlaceholder('半截$kInterruptedSuffix'), isTrue);
      expect(isInterruptedPlaceholder('完整回复,无后缀'), isFalse);
      expect(isInterruptedPlaceholder(null), isFalse);
      expect(isInterruptedPlaceholder(''), isFalse); // 空串非占位
    });

    test('interruptedPrefix: 去后缀得半截;非占位返回 null', () {
      expect(interruptedPrefix('半截$kInterruptedSuffix'), '半截');
      expect(interruptedPrefix('完整回复'), null);
      expect(interruptedPrefix(null), null);
    });

    test('interruptedPlaceholderCoveredBy: 半截是 full 前缀则覆盖', () {
      const full = '明白,仅分析不操作。用 sudo 深入查看。';
      expect(
        interruptedPlaceholderCoveredBy('明白,仅分析$kInterruptedSuffix', full),
        isTrue,
      );
      // 半截不是 full 的前缀 → 不覆盖
      expect(
        interruptedPlaceholderCoveredBy('毫不相关$kInterruptedSuffix', full),
        isFalse,
      );
      // 非占位行 → 不覆盖
      expect(interruptedPlaceholderCoveredBy('完整回复', full), isFalse);
    });

    test('半截为空(流刚开即断)不视为覆盖,避免单字符误删', () {
      expect(interruptedPlaceholderCoveredBy(kInterruptedSuffix, '任何回复'),
          isFalse);
    });
  });

  group('reconcileInterruptedPlaceholders', () {
    test('占位行被完整回复覆盖 → 删占位留完整', () async {
      final cache = CacheService();
      const acc = 'a';
      const full = '明白,仅分析不操作。用 sudo 深入查看。';
      // 先落占位行(熄屏假中断),再落完整回复(重连拿到 final)。
      await cache.upsertBotText(
          _botText('明白,仅分析$kInterruptedSuffix', 1700000000000),
          accountId: acc);
      await cache.upsertBotText(_botText(full, 1700000001000), accountId: acc);
      final removed =
          await cache.reconcileInterruptedPlaceholders(accountId: acc);
      expect(removed, 1);
      final msgs = await cache.getMessages(accountId: acc);
      expect(msgs.length, 1);
      expect(msgs.first.content, full);
      expect(isInterruptedPlaceholder(msgs.first.content), isFalse);
    });

    test('无完整回复覆盖(真断连) → 占位行保留', () async {
      final cache = CacheService();
      const acc = 'a';
      await cache.upsertBotText(
          _botText('半截$kInterruptedSuffix', 1700000000000), accountId: acc);
      final removed =
          await cache.reconcileInterruptedPlaceholders(accountId: acc);
      expect(removed, 0);
      final msgs = await cache.getMessages(accountId: acc);
      expect(msgs.length, 1);
      expect(isInterruptedPlaceholder(msgs.first.content), isTrue);
    });

    test('占位行与不相关完整回复 → 占位行保留', () async {
      final cache = CacheService();
      const acc = 'a';
      await cache.upsertBotText(
          _botText('半截$kInterruptedSuffix', 1700000000000), accountId: acc);
      await cache.upsertBotText(_botText('完全不同的另一条回复', 1700000002000),
          accountId: acc);
      final removed =
          await cache.reconcileInterruptedPlaceholders(accountId: acc);
      expect(removed, 0);
      expect((await cache.getMessages(accountId: acc)).length, 2);
    });

    test('多条占位行各被其完整回复覆盖 → 全删', () async {
      final cache = CacheService();
      const acc = 'a';
      await cache.upsertBotText(
          _botText('答案一前缀$kInterruptedSuffix', 1700000000000),
          accountId: acc);
      await cache.upsertBotText(
          _botText('答案二前缀$kInterruptedSuffix', 1700000001000),
          accountId: acc);
      await cache.upsertBotText(_botText('答案一前缀+后续', 1700000002000),
          accountId: acc);
      await cache.upsertBotText(_botText('答案二前缀+尾续', 1700000003000),
          accountId: acc);
      final removed =
          await cache.reconcileInterruptedPlaceholders(accountId: acc);
      expect(removed, 2);
      final msgs = await cache.getMessages(accountId: acc);
      expect(msgs.length, 2);
      expect(msgs.every((m) => !isInterruptedPlaceholder(m.content)), isTrue);
    });
  });

  group('mergeHistory 末尾自动 reconcile', () {
    test('incoming 完整历史行覆盖既有占位行 → 占位行被删', () async {
      final cache = CacheService();
      const acc = 'a';
      const full = '明白,仅分析不操作。用 sudo 深入查看。';
      // 熄屏时落了占位行
      await cache.upsertBotText(
          _botText('明白,仅分析$kInterruptedSuffix', 1700000000000),
          accountId: acc);
      // 回前台 connect() 全量拉历史,服务端有完整回复
      await cache.mergeHistory([
        HistoryRow(
            messageId: 101,
            role: 'assistant',
            type: 'text',
            content: full,
            timestamp: 1700000000)
      ], accountId: acc);
      final msgs = await cache.getMessages(accountId: acc);
      expect(msgs.length, 1, reason: '占位行被完整历史行覆盖,mergeHistory 末尾自动清除');
      expect(msgs.first.content, full);
      expect(msgs.first.serverId, 101);
    });

    test('incoming 历史行不含覆盖者 → 占位行保留', () async {
      final cache = CacheService();
      const acc = 'a';
      await cache.upsertBotText(
          _botText('半截$kInterruptedSuffix', 1700000000000), accountId: acc);
      await cache.mergeHistory([
        HistoryRow(
            messageId: 101,
            role: 'assistant',
            type: 'text',
            content: '毫不相关',
            timestamp: 1700000000)
      ], accountId: acc);
      final msgs = await cache.getMessages(accountId: acc);
      expect(msgs.length, 2);
      expect(msgs.any((m) => isInterruptedPlaceholder(m.content)), isTrue);
    });
  });
}
