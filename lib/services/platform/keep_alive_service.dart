// lib/services/platform/keep_alive_service.dart
//
// 前台保活抽象:移动端用 flutter_foreground_task 常驻通知保持进程存活,
// 桌面端 no-op(窗口开即活,关即断)。调用点面向接口,不知平台。
abstract class KeepAliveService {
  /// 启动时调一次(注册通知渠道等)。幂等。
  Future<void> init();

  /// 启动保活(幂等,best-effort,失败不抛)。
  Future<void> start();

  /// 停止保活。
  Future<void> stop();
}
