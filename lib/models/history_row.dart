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
