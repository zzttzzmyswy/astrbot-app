// test/lifecycle_reconnect_test.dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/util/lifecycle_reconnect.dart';

void main() {
  group('shouldReconnectOnResume', () {
    test('回到前台且当前未连接 → 应重连', () {
      expect(
          shouldReconnectOnResume(
              current: AppLifecycleState.resumed, isConnected: false),
          isTrue);
    });
    test('回到前台但已连接 → 不重连', () {
      expect(
          shouldReconnectOnResume(
              current: AppLifecycleState.resumed, isConnected: true),
          isFalse);
    });
    test('非 resumed 状态 → 不触发', () {
      expect(
          shouldReconnectOnResume(
              current: AppLifecycleState.paused, isConnected: false),
          isFalse);
      expect(
          shouldReconnectOnResume(
              current: AppLifecycleState.hidden, isConnected: false),
          isFalse);
    });
  });
}
