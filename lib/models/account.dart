// lib/models/account.dart
//
// 账户 = 一个 botapi token + serverUrl（对接一个 bot/对话）。
// label 为用户自定义名；为空时 UI 用 id 前 4 位派生。
class Account {
  final String id;
  final String? label;
  final String serverUrl;
  final String token;
  final int createdAt;
  final int lastUsedAt;

  const Account({
    required this.id,
    required this.serverUrl,
    required this.token,
    required this.createdAt,
    required this.lastUsedAt,
    this.label,
  });

  String get displayName {
    final l = label;
    if (l != null && l.isNotEmpty) return l;
    return 'Bot ${id.length >= 4 ? id.substring(0, 4) : id}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        if (label != null) 'label': label,
        'serverUrl': serverUrl,
        'token': token,
        'createdAt': createdAt,
        'lastUsedAt': lastUsedAt,
      };

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        id: json['id'] as String,
        label: json['label'] as String?,
        serverUrl: json['serverUrl'] as String,
        token: json['token'] as String,
        createdAt: (json['createdAt'] as num).toInt(),
        lastUsedAt: (json['lastUsedAt'] as num).toInt(),
      );

  Account copyWith({
    String? id,
    Object? label = _unset,
    String? serverUrl,
    String? token,
    int? createdAt,
    int? lastUsedAt,
  }) =>
      Account(
        id: id ?? this.id,
        label: identical(label, _unset) ? this.label : label as String?,
        serverUrl: serverUrl ?? this.serverUrl,
        token: token ?? this.token,
        createdAt: createdAt ?? this.createdAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      );
}

class _Unset {
  const _Unset();
}

const _unset = _Unset();
