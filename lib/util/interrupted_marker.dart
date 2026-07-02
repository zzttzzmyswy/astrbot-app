// lib/util/interrupted_marker.dart

/// 流式中断时落库的占位后缀。
///
/// `ChatNotifier._flushInterruptedStream` 在 SSE 中途断开时,把已累积的半截
/// 文本加上此后缀作为「中断占位行」入库,提示用户回复被打断。
///
/// 后缀使占位行 content 与服务端完整回复不同,故 `CacheService.upsertBotText`
/// / `CacheService.mergeHistory` 的按内容精确去重都命中不了 → 占位行与随后
/// 捞到的完整回复会并存(熄屏假中断后重连最易触发,用户实测「一条中断半截
/// + 一条完整」)。`CacheService.reconcileInterruptedPlaceholders` 据此后缀
/// 识别占位行,并在完整回复到达时将其清除。
const String kInterruptedSuffix = '\n\n_(回复中断,请重试)_';

/// 是否为中断占位行(content 以 [kInterruptedSuffix] 结尾)。
bool isInterruptedPlaceholder(String? content) =>
    content != null && content.endsWith(kInterruptedSuffix);

/// 去掉后缀,得到中断时已累积的半截文本;非占位行返回 null。
String? interruptedPrefix(String? content) {
  if (!isInterruptedPlaceholder(content)) return null;
  return content!.substring(0, content.length - kInterruptedSuffix.length);
}

/// 完整回复 [full] 是否覆盖该 content 代表的中断占位行。
///
/// 占位行去后缀得到的半截,若是 [full] 的前缀(流式 delta 累积本就是完整
/// 回复的开头),则该占位行已被完整回复取代,应清除。半截为空(流刚开即断)
/// 不视为覆盖,避免单字符前缀误删无关回复。
bool interruptedPlaceholderCoveredBy(String? content, String full) {
  final prefix = interruptedPrefix(content);
  return prefix != null && prefix.isNotEmpty && full.startsWith(prefix);
}
