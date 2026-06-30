// lib/util/stream_text.dart
import '../models/botapi_event.dart';

/// 累积 bot 流式文本，返回新的累积串。
///
/// 服务端 (astrbot_plugin_botapi/event.py) 的流式协议：
/// - 每个 plain delta `t` 即时广播（streaming:true，无 segment_end）；
/// - 遇到 `break`（agent 调用工具时分段）时，把本段已发 delta 的累计全文
///   `"".join(_text_buf)` 作为 `segment_end:true` **再广播一次**。
///
/// 因此 `segment_end` 的 content 是本段 delta 的累计重述，直接追加会整段翻倍
/// （用户实测的「明白明白 仅仅分析分析…」逐词翻倍即源于此）。此处跳过段累计；
/// 中途断连重连漏掉的 delta 由 `final` 全文 + 历史合并兜底，不在此处补救。
String accumulateStreamText(String current, BotApiEvent e) {
  if (!e.isStreamingText) return current;
  if (e.segmentEnd == true) return current; // 段累计重述，跳过避免翻倍
  return current + (e.content ?? '');
}
