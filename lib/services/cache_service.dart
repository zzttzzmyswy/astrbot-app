// lib/services/cache_service.dart
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import '../models/message.dart';
import '../models/history_row.dart';

/// 决定一条历史行如何合并：
/// - server_id 已在本地存在 → skip
/// - 存在同内容实时行（live，server_id 为空）→ link（贴 server_id）
/// - 否则 → insert
enum HistoryMergeAction { skip, link, insert }

HistoryMergeAction historyMergePlan({
  required HistoryRow row,
  required Set<int> existingServerIds,
  required bool existingLiveMatch,
}) {
  if (existingServerIds.contains(row.messageId)) return HistoryMergeAction.skip;
  if (existingLiveMatch) return HistoryMergeAction.link;
  return HistoryMergeAction.insert;
}

class CacheService {
  static Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = '$dbPath/astrbot_messages.db';
    return openDatabase(
      path,
      version: 6,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            msg_type TEXT NOT NULL,
            content TEXT,
            attachment_id TEXT,
            local_path TEXT,
            is_from_me INTEGER NOT NULL,
            status TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            session_id TEXT,
            server_id INTEGER
          )
        ''');
        await _dedupMessages(db);
        await _buildSessionIndex(db);
        await _buildServerIndex(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute('ALTER TABLE messages ADD COLUMN local_path TEXT');
        }
        if (oldV < 4) {
          // 一次性清理存量重复行（详见 _dedupMessages）。
          await _dedupMessages(db);
        }
        if (oldV < 5) {
          // 多会话：消息按 session_id 分区。
          await db.execute('ALTER TABLE messages ADD COLUMN session_id TEXT');
          await _buildSessionIndex(db);
        }
        if (oldV < 6) {
          // botapi：历史行带 server_id（int），用于去重。
          await db.execute('ALTER TABLE messages ADD COLUMN server_id INTEGER');
          await _buildServerIndex(db);
        }
      },
    );
  }

  Future<void> _buildSessionIndex(Database db) async {
    try {
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id)');
    } catch (_) {}
  }

  Future<void> _buildServerIndex(Database db) async {
    try {
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_messages_server ON messages(server_id)');
    } catch (_) {}
  }

  /// 迁移标记：若 config 迁移设置了 wipe 标记，清空消息表并清标记。
  Future<void> wipeIfFlagged(SharedPreferences prefs) async {
    if (prefs.getBool('botapi_wipe_messages') == true) {
      await clearAll();
      await prefs.remove('botapi_wipe_messages');
    }
  }

  /// 回填：把 session_id 为 NULL 的存量行归到指定 account_id（升级用）。
  Future<void> backfillSession(String accountId) async {
    final d = await db;
    await d.rawUpdate(
        'UPDATE messages SET session_id = ? WHERE session_id IS NULL',
        [accountId]);
  }

  /// 新会话首条消息：在服务端回传 id 之前插入的消息 session_id 为空，
  /// 服务端回传后用本方法把它们「认领」到新 account_id。
  Future<void> adoptOrphans(String accountId) async {
    final d = await db;
    await d.rawUpdate(
        "UPDATE messages SET session_id = ? WHERE session_id IS NULL OR session_id = ''",
        [accountId]);
  }

  Future<void> _dedupMessages(Database db) async {
    await db.execute('''
      DELETE FROM messages WHERE id NOT IN (
        SELECT MIN(id) FROM messages
        GROUP BY is_from_me, msg_type, COALESCE(content, ''),
                 COALESCE(attachment_id, ''), created_at / 300000
      )
    ''');
  }

  Future<int> insertMessage(LocalMessage msg, {String? accountId}) async {
    final d = await db;
    return d.insert('messages', msg.toMap()..['session_id'] = accountId);
  }

  /// 插入 bot 文本消息，若近 5 分钟内已存在相同内容(!is_from_me)则跳过。
  Future<void> upsertBotText(LocalMessage msg, {String? accountId}) async {
    final d = await db;
    await d.transaction((txn) async {
      final rows = await txn.query(
        'messages',
        where:
            'is_from_me = 0 AND content = ? AND created_at > ? AND session_id IS ?',
        whereArgs: [
          msg.content ?? '',
          msg.createdAt - 300000,
          accountId,
        ],
        limit: 1,
      );
      if (rows.isEmpty) {
        await txn.insert('messages', msg.toMap()..['session_id'] = accountId);
      }
    });
  }

  Future<bool> hasAttachmentId(String id, {String? accountId}) async {
    final d = await db;
    final rows = await d.query('messages',
        where: 'attachment_id = ? AND session_id IS ?',
        whereArgs: [id, accountId],
        limit: 1);
    return rows.isNotEmpty;
  }

  /// Insert or update by created_at（媒体消息状态随时间变化用）。
  Future<void> upsert(LocalMessage msg, {String? accountId}) async {
    final d = await db;
    await d.transaction((txn) async {
      final rows = await txn.query('messages',
          where: 'created_at = ? AND session_id IS ?',
          whereArgs: [msg.createdAt, accountId],
          limit: 1);
      if (rows.isEmpty) {
        await txn.insert('messages', msg.toMap()..['session_id'] = accountId);
      } else {
        await txn.update('messages', msg.toMap()..['session_id'] = accountId,
            where: 'id = ?', whereArgs: [rows.first['id']]);
      }
    });
  }

  /// 读取指定账户的消息。[limit] 为 null 时加载全部；返回按时间正序。
  Future<List<LocalMessage>> getMessages(
      {String? accountId, int? limit, int offset = 0}) async {
    final d = await db;
    final rows = accountId == null
        ? await d.query('messages', orderBy: 'created_at DESC', limit: limit, offset: offset)
        : await d.query('messages',
            where: 'session_id IS ?',
            whereArgs: [accountId],
            orderBy: 'created_at DESC',
            limit: limit,
            offset: offset);
    return rows.map((r) => LocalMessage.fromMap(r)).toList().reversed.toList();
  }

  /// 删除指定账户的全部消息（删除账户时调用）。
  Future<void> clearSession(String accountId) async {
    final d = await db;
    await d.delete('messages', where: 'session_id = ?', whereArgs: [accountId]);
  }

  /// 合并 botapi 历史行：按 server_id 去重；已存在同内容实时行则贴 server_id；
  /// 全新则插入。返回合并后该账户的最大 server_id（用于 stream since 游标）。
  Future<int> mergeHistory(List<HistoryRow> rows, {required String accountId}) async {
    if (rows.isEmpty) return 0;
    final d = await db;
    int maxId = 0;
    for (final row in rows) {
      if (row.messageId > maxId) maxId = row.messageId;
      final existing = await d.query('messages',
          where: 'session_id = ? AND server_id = ?',
          whereArgs: [accountId, row.messageId],
          limit: 1);
      if (existing.isNotEmpty) continue; // skip
      // 查同内容实时行（server_id 为空，内容+角色+时间窗匹配）
      final live = await d.query('messages',
          where:
              'session_id = ? AND server_id IS NULL AND is_from_me = ? AND content = ? AND created_at > ?',
          whereArgs: [
            accountId,
            row.role == 'user' ? 1 : 0,
            row.content,
            (row.timestamp * 1000) - 300000
          ],
          limit: 1);
      if (live.isNotEmpty) {
        await d.update('messages', {'server_id': row.messageId},
            where: 'id = ?', whereArgs: [live.first['id']]);
      } else {
        await d.insert('messages', {
          'msg_type': row.type == 'thinking' ? 'thinking' : 'text',
          'content': row.content,
          'is_from_me': row.role == 'user' ? 1 : 0,
          'status': 'sent',
          'created_at': row.timestamp * 1000,
          'session_id': accountId,
          'server_id': row.messageId,
        });
      }
    }
    return maxId;
  }

  /// 当前账户本地最大 server_id（用于 stream since 游标；无则 0）。
  Future<int> maxServerId(String accountId) async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT MAX(server_id) AS m FROM messages WHERE session_id = ?', [accountId]);
    final m = rows.first['m'];
    return (m as num?)?.toInt() ?? 0;
  }

  Future<void> clearAll() async {
    final d = await db;
    await d.delete('messages');
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
