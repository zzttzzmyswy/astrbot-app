// lib/models/chat_event.dart
import 'dart:convert';

enum ConnState { disconnected, connecting, reconnecting, connected }

class ChatEvent {
  final String type;
  final String? data;
  final bool? streaming;
  final String? sessionId;
  final String? code;
  final String? chainType;
  final Map<String, dynamic>? raw;

  ChatEvent({
    required this.type,
    this.data,
    this.streaming,
    this.sessionId,
    this.code,
    this.chainType,
    this.raw,
  });

  factory ChatEvent.fromJson(Map<String, dynamic> json) {
    return ChatEvent(
      type: json['type'] as String? ?? '',
      data: json['data'] is String
          ? json['data']
          : (json['data'] != null ? jsonEncode(json['data']) : null),
      streaming: json['streaming'] as bool?,
      sessionId: json['session_id'] as String?,
      code: json['code'] as String?,
      chainType: json['chain_type'] as String?,
      raw: json,
    );
  }

  bool get isEnd => type == 'end';
  bool get isError => type == 'error';
  bool get isAttachmentSaved => type == 'attachment_saved';
  bool get isToolCall => chainType == 'tool_call';
  bool get isToolCallResult => chainType == 'tool_call_result';
}
