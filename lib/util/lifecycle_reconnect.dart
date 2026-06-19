// lib/util/lifecycle_reconnect.dart
import 'package:flutter/widgets.dart';

/// 应用回到前台(resumed)且当前连接未建立时才需要重连。
/// 其他状态不触发——后台保活交给前台服务与心跳/存活检测。
bool shouldReconnectOnResume({
  required AppLifecycleState current,
  required bool isConnected,
}) {
  return current == AppLifecycleState.resumed && !isConnected;
}
