// lib/services/platform/impl/keep_alive_mobile.dart
//
// 移动端保活:flutter_foreground_task v8 常驻通知。搬迁自原 foreground_service.dart,
// 行为不变。keepAliveStartCallback 必须顶层 + @pragma('vm:entry-point') 防 tree-shaking。
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../keep_alive_service.dart';

class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

@pragma('vm:entry-point')
void keepAliveStartCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}

class MobileKeepAlive implements KeepAliveService {
  @override
  Future<void> init() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'astrbot_keepalive',
        channelName: 'Bot助手 后台运行',
        channelDescription: '保持与服务器的连接，防止丢失消息',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  @override
  Future<void> start() async {
    try {
      await FlutterForegroundTask.requestNotificationPermission();
      if (await FlutterForegroundTask.isRunningService) return;
      final result = await FlutterForegroundTask.startService(
        notificationTitle: 'Bot助手 正在运行',
        notificationText: '保持连接以接收新消息',
        callback: keepAliveStartCallback,
      );
      final _ = result; // ServiceRequestSuccess | Failure,忽略
    } catch (_) {
      // best-effort,绝不因保活崩 app。
    }
  }

  @override
  Future<void> stop() async {
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }
}
