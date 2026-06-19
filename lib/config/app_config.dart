// lib/config/app_config.dart
class AppConfig {
  static const String appName = 'Bot助手';
  static const String defaultServerUrl = 'https://your-astrbot-host.example.com';
  static const String defaultConfigId = 'my_bot';
  static const String defaultConnectionMode = 'sse';
  static const int wsReconnectBaseMs = 1000;
  static const int wsReconnectMaxMs = 30000;
  static const int wsPingIntervalSec = 30;
  static const int cacheRetentionDays = 7;
}
