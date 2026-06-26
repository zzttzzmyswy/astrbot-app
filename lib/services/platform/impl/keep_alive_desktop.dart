// lib/services/platform/impl/keep_alive_desktop.dart
import '../keep_alive_service.dart';

/// 桌面 no-op:窗口在则进程在,无需前台服务。绝不触碰 flutter_foreground_task
/// (该包桌面无实现,碰了会 MissingPluginError)。
class DesktopKeepAlive implements KeepAliveService {
  @override
  Future<void> init() async {}
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}
