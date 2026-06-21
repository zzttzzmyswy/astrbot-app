// lib/services/config_service.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';

class ConfigService {
  static const _kNickname = 'nickname';
  static const _kServerUrl = 'server_url';
  static const _kApiKey = 'api_key';
  static const _kConfigId = 'config_id';
  static const _kSessionId = 'session_id';
  static const _kIsConfigured = 'is_configured';
  static const _kThemeMode = 'theme_mode';
  static const _kConnectionMode = 'connection_mode';
  static const _kAutoPlayVoice = 'auto_play_voice';
  // Bumped when we need to run a one-time prefs migration. Currently: force
  // existing installs off the buggy WS default onto SSE.
  static const _kPrefsVersion = 'prefs_version';
  static const int _kCurrentPrefsVersion = 2;

  late SharedPreferences _prefs;

  /// 暴露底层 prefs,供会话注册表(SessionStore)复用同一存储实例。
  SharedPreferences get prefs => _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _migrate();
  }

  Future<void> _migrate() async {
    final v = _prefs.getInt(_kPrefsVersion) ?? 1;
    if (v >= _kCurrentPrefsVersion) return;
    // v1 -> v2: WS mode loses large files / long text and drops sessions;
    // move everyone to the SSE default.
    if (v < 2 && _prefs.getString(_kConnectionMode) == 'ws') {
      await _prefs.setString(_kConnectionMode, 'sse');
    }
    await _prefs.setInt(_kPrefsVersion, _kCurrentPrefsVersion);
  }

  bool get isConfigured => _prefs.getBool(_kIsConfigured) ?? false;

  String get nickname => _prefs.getString(_kNickname) ?? '';
  String get serverUrl => _prefs.getString(_kServerUrl) ?? AppConfig.defaultServerUrl;
  String get apiKey => _prefs.getString(_kApiKey) ?? '';
  String get configId => _prefs.getString(_kConfigId) ?? AppConfig.defaultConfigId;
  String? get sessionId => _prefs.getString(_kSessionId);

  String get connectionMode => _prefs.getString(_kConnectionMode) ?? AppConfig.defaultConnectionMode;

  bool get autoPlayVoice => _prefs.getBool(_kAutoPlayVoice) ?? false;

  Future<void> setConnectionMode(String v) async => _prefs.setString(_kConnectionMode, v);

  Future<void> setAutoPlayVoice(bool v) async => _prefs.setBool(_kAutoPlayVoice, v);

  ThemeMode get themeMode {
    final v = _prefs.getString(_kThemeMode) ?? 'auto';
    switch (v) {
      case 'light': return ThemeMode.light;
      case 'dark': return ThemeMode.dark;
      default: return ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    String v;
    switch (mode) {
      case ThemeMode.light: v = 'light';
      case ThemeMode.dark: v = 'dark';
      default: v = 'auto';
    }
    await _prefs.setString(_kThemeMode, v);
  }

  Future<void> setNickname(String v) async => _prefs.setString(_kNickname, v);
  Future<void> setServerUrl(String v) async => _prefs.setString(_kServerUrl, v);
  Future<void> setApiKey(String v) async => _prefs.setString(_kApiKey, v);
  Future<void> setConfigId(String v) async => _prefs.setString(_kConfigId, v);
  Future<void> setSessionId(String v) async => _prefs.setString(_kSessionId, v);

  Future<void> saveSetup({
    required String nickname,
    required String serverUrl,
    required String apiKey,
    required String configId,
  }) async {
    await setNickname(nickname);
    await setServerUrl(serverUrl);
    await setApiKey(apiKey);
    await setConfigId(configId);
    await _prefs.setBool(_kIsConfigured, true);
  }
}
