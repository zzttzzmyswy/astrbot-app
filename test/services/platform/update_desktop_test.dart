import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/services/platform/impl/update_desktop.dart';
import 'package:astrbot_app/services/update_service.dart';

void main() {
  group('DesktopUpdateApplier', () {
    test('actionLabel 为「打开下载页」', () {
      expect(DesktopUpdateApplier().actionLabel, '打开下载页');
    });

    test('空 apkUrl 不抛、不打开', () async {
      final a = DesktopUpdateApplier();
      const info = UpdateInfo(
          tag: '', version: '', notes: '', apkUrl: '', apkSize: 0);
      await a.apply(info);
    });

    test('非 http(s) scheme 不打开', () async {
      final a = DesktopUpdateApplier();
      const info = UpdateInfo(
          tag: '', version: '', notes: '', apkUrl: 'javascript:alert(1)', apkSize: 0);
      await a.apply(info);
    });
  });
}
