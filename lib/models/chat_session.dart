// lib/models/chat_session.dart
//
// 会话注册表条目(纯数据 + serde,便于单测)。
// id = 服务端分配的 session_id(uuid,首条消息后经 session_id 事件回传)。
// name = 用户自定义显示名;为 null 时 UI 用 id 派生的初始名(取 id 前 8 位 hex)。

class ChatSession {
  final String id;
  final String? name;
  final int createdAt;
  final int lastUsedAt;

  const ChatSession({
    required this.id,
    required this.createdAt,
    required this.lastUsedAt,
    this.name,
  });

  /// 从服务端 session_id 派生的初始显示名(取前 8 位)。
  /// 「聊天开始后从服务器获取」:session_id 由服务端在首条消息后回传,
  /// 派生名即基于该服务端身份,用户可改名覆盖。
  static String derivedName(String id) {
    final head = id.length >= 8 ? id.substring(0, 8) : id;
    return head;
  }

  /// 实际展示名:用户自定义优先,否则派生名。
  String get displayName => name?.isNotEmpty == true ? name! : derivedName(id);

  Map<String, dynamic> toJson() => {
        'id': id,
        if (name != null) 'name': name,
        'createdAt': createdAt,
        'lastUsedAt': lastUsedAt,
      };

  factory ChatSession.fromJson(Map<String, dynamic> json) => ChatSession(
        id: json['id'] as String,
        name: json['name'] as String?,
        createdAt: (json['createdAt'] as num).toInt(),
        lastUsedAt: (json['lastUsedAt'] as num).toInt(),
      );

  ChatSession copyWith({
    String? id,
    Object? name = _unset,
    int? createdAt,
    int? lastUsedAt,
  }) =>
      ChatSession(
        id: id ?? this.id,
        name: identical(name, _unset) ? this.name : name as String?,
        createdAt: createdAt ?? this.createdAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      );
}

class _Unset {
  const _Unset();
}

const _unset = _Unset();
