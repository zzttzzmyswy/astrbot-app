// test/key_mask_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/util/key_mask.dart';

void main() {
  group('maskKey', () {
    test('长 key 截断为前 10 位 + 掩码', () {
      // visible=10 默认
      final r = maskKey('sk-abcdefghij1234567');
      expect(r.startsWith('sk-abcdefg'), isTrue); // 前 10 位明文
      expect(r.contains('•'), isTrue);
      // 10 明文 + 掩码;不再包含 10 位之后的明文
      expect(r.contains('1234567'), isFalse);
    });

    test('恰好 10 位不掩码', () {
      expect(maskKey('0123456789'), '0123456789');
    });

    test('短于 visible 全部明文', () {
      expect(maskKey('short'), 'short');
      expect(maskKey(''), '');
    });

    test('掩码长度受 maxMask 封顶', () {
      // 50 位 key:前 10 明文 + 剩 40 位,但 maxMask=12 → 只 12 个点
      final r = maskKey('a' * 50);
      expect(r.length, 10 + 12);
      // 自定义 maxMask
      expect(maskKey('a' * 50, maxMask: 4).length, 10 + 4);
    });

    test('自定义 visible', () {
      final r = maskKey('0123456789abcdef', visible: 4);
      expect(r.startsWith('0123'), isTrue);
      expect(r.length, 4 + 12); // 剩 12 位 ≤ maxMask=12
    });
  });
}
