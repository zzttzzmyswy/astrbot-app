// test/cache_service_history_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/services/cache_service.dart';
import 'package:astrbot_app/models/history_row.dart';

void main() {
  group('historyMergePlan', () {
    test('server_id 已存在 → skip', () {
      final plan = historyMergePlan(
        row: const HistoryRow(
            messageId: 5, role: 'assistant', type: 'text', content: 'x', timestamp: 1),
        existingServerIds: const {5},
        existingLiveMatch: false,
      );
      expect(plan, HistoryMergeAction.skip);
    });
    test('存在同内容实时行 → link', () {
      final plan = historyMergePlan(
        row: const HistoryRow(
            messageId: 5, role: 'assistant', type: 'text', content: 'x', timestamp: 1),
        existingServerIds: const {},
        existingLiveMatch: true,
      );
      expect(plan, HistoryMergeAction.link);
    });
    test('link 优先于 skip？否：server_id 已存在优先 skip', () {
      // 既有 server_id 又有实时匹配（不应同时发生）→ skip（幂等）
      final plan = historyMergePlan(
        row: const HistoryRow(
            messageId: 5, role: 'assistant', type: 'text', content: 'x', timestamp: 1),
        existingServerIds: const {5},
        existingLiveMatch: true,
      );
      expect(plan, HistoryMergeAction.skip);
    });
    test('全新 → insert', () {
      final plan = historyMergePlan(
        row: const HistoryRow(
            messageId: 5, role: 'user', type: 'text', content: 'hi', timestamp: 1),
        existingServerIds: const {},
        existingLiveMatch: false,
      );
      expect(plan, HistoryMergeAction.insert);
    });
  });
}
