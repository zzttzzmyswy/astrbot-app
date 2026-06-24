// lib/services/account_store.dart
//
// 账户注册表纯逻辑（依赖 AccountStorage 抽象，便于单测用内存实现）。
// 职责：加载/持久化账户列表与当前账户 id；增删改；25 上限；切换当前账户；
// 删除当前账户时切到另一个（或占位）。
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/account.dart';

abstract class AccountStorage {
  Future<String?> readString(String key);
  Future<void> writeString(String key, String value);
}

const _kAccountsKey = 'accounts_v1';
const _kCurrentIdKey = 'accounts_current_v1';

/// 单用户最多保留的账户数（产品约束）。
const int kMaxAccounts = 25;

/// 未添加任何账户时的占位 currentId。
const String kNoAccount = '';

class AccountStore {
  final AccountStorage _storage;
  AccountStore(this._storage);

  List<Account> _accounts = const [];
  String? _currentId;
  bool _loaded = false;

  List<Account> get accounts {
    _ensureLoaded();
    return List.unmodifiable(_accounts);
  }

  String get currentId {
    _ensureLoaded();
    return _currentId ?? kNoAccount;
  }

  void _ensureLoaded() {
    if (!_loaded) {
      throw StateError('AccountStore 未加载，先调用 load()');
    }
  }

  Future<void> load() async {
    final raw = await _storage.readString(_kAccountsKey);
    List<Account> list = const [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final arr = jsonDecode(raw);
        if (arr is List) {
          list = arr
              .map((e) => (e is Map) ? Map<String, dynamic>.from(e) : <String, dynamic>{})
              .map(Account.fromJson)
              .toList();
        }
      } catch (_) {
        list = const []; // 损坏 JSON 不致命
      }
    }
    _accounts = _sortByLastUsed(list);
    _currentId = await _storage.readString(_kCurrentIdKey) ?? kNoAccount;
    if (_currentId == kNoAccount && _accounts.isNotEmpty) {
      _currentId = _accounts.first.id; // 容错：有账户但无 current 记录
    }
    _loaded = true;
  }

  /// 新增账户。返回新账户；已达 25 上限返回 null。
  Future<Account?> add({
    required String serverUrl,
    required String token,
    String? label,
  }) async {
    _ensureLoaded();
    if (_accounts.length >= kMaxAccounts) return null;
    final now = _nowMs();
    final a = Account(
      id: _uuid(),
      serverUrl: serverUrl,
      token: token,
      label: label,
      createdAt: now,
      lastUsedAt: now,
    );
    _accounts = _sortByLastUsed([..._accounts, a]);
    _currentId = a.id;
    await _persist();
    return a;
  }

  Future<bool> select(String id) async {
    _ensureLoaded();
    final idx = _accounts.indexWhere((a) => a.id == id);
    if (idx < 0) return false;
    final now = _nowMs();
    final list = [..._accounts]..[idx] = _accounts[idx].copyWith(lastUsedAt: now);
    _accounts = _sortByLastUsed(list);
    _currentId = id;
    await _persist();
    return true;
  }

  Future<bool> rename(String id, String? label) async {
    _ensureLoaded();
    final idx = _accounts.indexWhere((a) => a.id == id);
    if (idx < 0) return false;
    final trimmed = label?.trim();
    final list = [..._accounts]..[idx] = _accounts[idx].copyWith(
        label: (trimmed == null || trimmed.isEmpty) ? null : trimmed);
    _accounts = list;
    await _persist();
    return true;
  }

  Future<bool> updateCredentials(String id,
      {required String serverUrl, required String token}) async {
    _ensureLoaded();
    final idx = _accounts.indexWhere((a) => a.id == id);
    if (idx < 0) return false;
    final list = [..._accounts]
      ..[idx] = _accounts[idx].copyWith(serverUrl: serverUrl, token: token);
    _accounts = list;
    await _persist();
    return true;
  }

  /// 删除账户。返回删除后应切换到的 currentId。
  Future<String> delete(String id,
      {required Future<void> Function(String) deleteMessages}) async {
    _ensureLoaded();
    _accounts = _accounts.where((a) => a.id != id).toList();
    await deleteMessages(id);
    String next;
    if (_currentId == id) {
      next = _accounts.isEmpty ? kNoAccount : _accounts.first.id;
      _currentId = next;
      await _persist();
    } else {
      await _persist();
      next = _currentId ?? kNoAccount;
    }
    return next;
  }

  Future<void> touchCurrent({required int nowMs}) async {
    _ensureLoaded();
    if (_currentId == null || _currentId == kNoAccount) return;
    final idx = _accounts.indexWhere((a) => a.id == _currentId);
    if (idx < 0) return;
    final list = [..._accounts]..[idx] = _accounts[idx].copyWith(lastUsedAt: nowMs);
    _accounts = _sortByLastUsed(list);
    await _persist();
  }

  Future<void> _persist() async {
    final arr = _accounts.map((a) => a.toJson()).toList();
    await _storage.writeString(_kAccountsKey, jsonEncode(arr));
    await _storage.writeString(_kCurrentIdKey, _currentId ?? kNoAccount);
  }
}

// ---- 排序、时间、id ----
List<Account> _sortByLastUsed(List<Account> list) {
  final copy = [...list]..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
  return copy;
}

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

int _uuidCounter = 0;

/// 本地账户 id：时间戳 + 自增计数器（避免同毫秒多 add 碰撞）。
String _uuid() {
  _uuidCounter += 1;
  return '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${_uuidCounter.toRadixString(36)}';
}

/// 生产用 SharedPreferences 包装。
class PrefsAccountStorage implements AccountStorage {
  final SharedPreferences _prefs;
  PrefsAccountStorage(this._prefs);
  @override
  Future<String?> readString(String key) async => _prefs.getString(key);
  @override
  Future<void> writeString(String key, String value) async =>
      _prefs.setString(key, value);
}
