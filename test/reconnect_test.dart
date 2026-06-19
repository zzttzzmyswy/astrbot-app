// test/reconnect_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/util/reconnect.dart';

void main() {
  group('reconnectDelayMs', () {
    test('第 0 次失败后延迟 1000ms(基数)', () {
      expect(reconnectDelayMs(0, baseMs: 1000, maxMs: 30000), 1000);
    });
    test('指数退避 1→2→4→8 秒', () {
      expect(reconnectDelayMs(1, baseMs: 1000, maxMs: 30000), 2000);
      expect(reconnectDelayMs(2, baseMs: 1000, maxMs: 30000), 4000);
      expect(reconnectDelayMs(3, baseMs: 1000, maxMs: 30000), 8000);
    });
    test('封顶 maxMs', () {
      expect(reconnectDelayMs(20, baseMs: 1000, maxMs: 30000), 30000);
    });
  });

  group('ReconnectAttempt', () {
    test('失败递增、成功清零', () {
      final a = ReconnectAttempt();
      expect(a.nextDelay(baseMs: 1000, maxMs: 30000), 1000);
      a.recordFailure();
      expect(a.nextDelay(baseMs: 1000, maxMs: 30000), 2000);
      a.recordFailure();
      expect(a.nextDelay(baseMs: 1000, maxMs: 30000), 4000);
      a.reset();
      expect(a.nextDelay(baseMs: 1000, maxMs: 30000), 1000);
    });
  });
}
