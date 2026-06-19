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
    msgs
        .map((m) => (m.isFromMe && m.createdAt == createdAt)
            ? m.copyWith(status: MessageStatus.error)
            : m)
        .toList();

/// 把指定 createdAt 的消息回退为 pending(重发前复位)。
List<LocalMessage> setMessagePending(List<LocalMessage> msgs, int createdAt) =>
    msgs
        .map((m) => (m.createdAt == createdAt)
            ? m.copyWith(status: MessageStatus.pending)
            : m)
        .toList();
