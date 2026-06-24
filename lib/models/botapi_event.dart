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
  bool get isMedia =>
      isMessage && (type == 'image' || type == 'audio' || type == 'file');
}
