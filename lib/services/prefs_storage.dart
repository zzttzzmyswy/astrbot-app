// lib/services/prefs_storage.dart
//
// SessionStorage 的 SharedPreferences 实现(生产路径)。
// 与 session_store 的纯逻辑解耦:测试用内存实现,生产用本类。

import 'package:shared_preferences/shared_preferences.dart';

import 'session_store.dart';

class PrefsSessionStorage implements SessionStorage {
  final SharedPreferences _prefs;
  PrefsSessionStorage(this._prefs);

  @override
  Future<String?> readString(String key) async => _prefs.getString(key);

  @override
  Future<void> writeString(String key, String value) async =>
      _prefs.setString(key, value);
}
