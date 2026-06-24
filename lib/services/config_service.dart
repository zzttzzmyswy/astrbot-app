// lib/services/config_service.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ConfigService {
  static const _kIsConfigured = 'is_configured';
  static const _kThemeMode = 'theme_mode';
  static const _kAutoPlayVoice = 'auto_play_voice';
  // Bumped when we need a one-time prefs migration.
  // v3: 迁移到 botapi——清空旧 webchat 数据，重置 is_configured。
  static const _kPrefsVersion = 'prefs_version';
  static const int _kCurrentPrefsVersion = 3;

  late SharedPreferences _prefs;

  /// 暴露底层 prefs,供 AccountStore 复用同一存储实例。
  SharedPreferences get prefs => _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _migrate();
  }

  Future<void> _migrate() async {
    final v = _prefs.getInt(_kPrefsVersion) ?? 1;
    if (v >= _kCurrentPrefsVersion) return;
    if (v < 3) {
      // 旧 webchat 数据与 botapi 不兼容：清账户/会话注册表、凭据，重置配置态。
      // 主题/autoPlay 等偏好保留。消息表由 CacheService.wipeIfFlagged 在首启清空。
      await _prefs.remove('chat_sessions_v1');
      await _prefs.remove('chat_sessions_current_v1');
      await _prefs.remove('accounts_v1');
      await _prefs.remove('accounts_current_v1');
      await _prefs.remove('nickname');
      await _prefs.remove('server_url');
      await _prefs.remove('api_key');
      await _prefs.remove('config_id');
      await _prefs.remove('session_id');
      await _prefs.remove('connection_mode');
      await _prefs.setBool(_kIsConfigured, false);
      await _prefs.setBool('botapi_wipe_messages', true);
    }
    await _prefs.setInt(_kPrefsVersion, _kCurrentPrefsVersion);
  }

  bool get isConfigured => _prefs.getBool(_kIsConfigured) ?? false;
  Future<void> setConfigured(bool v) => _prefs.setBool(_kIsConfigured, v);

  bool get autoPlayVoice => _prefs.getBool(_kAutoPlayVoice) ?? false;
  Future<void> setAutoPlayVoice(bool v) => _prefs.setBool(_kAutoPlayVoice, v);

  ThemeMode get themeMode {
    final v = _prefs.getString(_kThemeMode) ?? 'auto';
    switch (v) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    String v;
    switch (mode) {
      case ThemeMode.light:
        v = 'light';
      case ThemeMode.dark:
        v = 'dark';
      default:
        v = 'auto';
    }
    await _prefs.setString(_kThemeMode, v);
  }
}
