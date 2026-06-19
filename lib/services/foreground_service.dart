// lib/services/foreground_service.dart
//
// Keeps the app process alive in the background via a foreground service +
// persistent notification, so the WebSocket / SSE connection to AstrBot is not
// torn down by the OS and no incoming messages are lost while the app is in
// the background. The task handler itself does no work — its only purpose is
// to keep the process (and thus the main isolate hosting the chat client)
// alive. Built on flutter_foreground_task v8.
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

/// Entry point for the foreground task isolate. Must be top-level and annotated
/// with @pragma('vm:entry-point') so it survives tree-shaking.
@pragma('vm:entry-point')
void keepAliveStartCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}

/// Call once during app startup (before any startService call).
void initKeepAliveService() {
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

/// Start the foreground service (idempotent). Best-effort: asks for notification
/// permission on Android 13+ first.
Future<void> startKeepAliveService() async {
  try {
    await FlutterForegroundTask.requestNotificationPermission();
    if (await FlutterForegroundTask.isRunningService) return;
    final result = await FlutterForegroundTask.startService(
      notificationTitle: 'Bot助手 正在运行',
      notificationText: '保持连接以接收新消息',
      callback: keepAliveStartCallback,
    );
    // result is ServiceRequestSuccess | ServiceRequestFailure; ignore failure.
    final _ = result;
  } catch (_) {
    // Foreground service is best-effort; never crash the app because of it.
  }
}
