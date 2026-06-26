import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/services/platform/impl/keep_alive_desktop.dart';

void main() {
  test('DesktopKeepAlive 全 no-op 且不抛', () async {
    final s = DesktopKeepAlive();
    await s.init();
    await s.start();
    await s.stop();
    expect(true, true); // 到这里没抛即通过
  });
}
