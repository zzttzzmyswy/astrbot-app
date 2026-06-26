import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/services/platform/impl/permission_desktop.dart';

void main() {
  test('DesktopPermission 永远 granted', () async {
    final p = DesktopPermission();
    expect(await p.hasMic(), true);
    expect(await p.requestMic(), true);
  });
}
