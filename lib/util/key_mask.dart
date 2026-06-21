// lib/util/key_mask.dart
//
// API Key / token 脱敏的纯逻辑(不碰平台,便于单测)。
// 默认只显示前 [visible] 个字符,其余用掩码点替换,便于设置页预览而不泄露完整密钥。

/// 把密钥脱敏为「前 [visible] 位明文 + 掩码」形式。
///
/// - key 长度 ≤ [visible]:全部明文返回(短 key 不掩码,避免误导成空)。
/// - 否则:返回前 [visible] 位 + [maskChar]×min(剩余长度, [maxMask])。
///   [maxMask] 封顶掩码长度,避免超长 key 把 UI 撑爆。
///
/// 例:maskKey('sk-abcdefghij1234') → 'sk-abcdefg••••••••••'(visible=10, maxMask=12)
String maskKey(String key, {int visible = 10, int maxMask = 12, String maskChar = '•'}) {
  if (key.length <= visible) return key;
  final tail = key.length - visible;
  final masked = maskChar * (tail < maxMask ? tail : maxMask);
  return '${key.substring(0, visible)}$masked';
}
