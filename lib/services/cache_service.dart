// lib/services/cache_service.dart
import 'package:sqflite/sqflite.dart';
import '../models/message.dart';

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
      version: 5,
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
            session_id TEXT
          )
        ''');
        await _dedupMessages(db);
        await _buildSessionIndex(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute('ALTER TABLE messages ADD COLUMN local_path TEXT');
        }
        if (oldV < 4) {
          // 一次性清理存量重复行。重复根因是 _handleEvent 同步、缓存写入 fire-
          // and-forget 不 await,导致 bot 一条媒体(raw 事件 + attachment_saved
          // 事件)或文本(complete + end 双触发)的两次 upsert 并发,各自的
          // query 都赶在对方 insert 前完成 → 都判空 → 都 insert → 落两行,
          // 随历史加载一直显示。详见 _dedupMessages 的时间桶策略。
          await _dedupMessages(db);
        }
        if (oldV < 5) {
          // 多会话:消息按 session_id 分区。新增列并回填到当前会话(由 provider
          // 在迁移后调用 backfillSession 把存量行归到当前/旧 session_id)。
          await db.execute('ALTER TABLE messages ADD COLUMN session_id TEXT');
          await _buildSessionIndex(db);
        }
      },
    );
  }

  Future<void> _buildSessionIndex(Database db) async {
    try {
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id)');
    } catch (_) {
      // 老库可能已存在该索引或列尚未就绪;忽略,查询仍可按 session_id 过滤。
    }
  }

  /// 回填:把当前库中 session_id 为 NULL 的存量行归到指定 session_id。
  /// 用于从单会话版本升级到多会话时,把历史消息绑定到当前会话。
  Future<void> backfillSession(String sessionId) async {
    final d = await db;
    await d.rawUpdate(
        'UPDATE messages SET session_id = ? WHERE session_id IS NULL',
        [sessionId]);
  }

  /// 新会话首条消息:在服务端回传 session_id 之前插入的消息 session_id 为空,
  /// 服务端回传后用本方法把它们「认领」到新会话 id。仅作用于 session_id 为空的行。
  Future<void> adoptOrphans(String sessionId) async {
    final d = await db;
    await d.rawUpdate(
        "UPDATE messages SET session_id = ? WHERE session_id IS NULL OR session_id = ''",
        [sessionId]);
  }

  Future<void> _dedupMessages(Database db) async {
    // 按 (发送方/类型/内容/attachment_id/5分钟时间桶) 分组,每组留最早一条。
    // 时间桶(created_at / 300000ms)确保只清掉同一轮内产生的重复(并发双写/
    // 重投递都在短窗内),而跨时间的合法相同回复(如多次问同样问题得到同样
    // 逐字回复)因落在不同桶而被保留。attachment_id 非空的媒体 id 全局唯一,
    // 任意桶内至多一条,天然安全。
    await db.execute('''
      DELETE FROM messages WHERE id NOT IN (
        SELECT MIN(id) FROM messages
        GROUP BY is_from_me, msg_type, COALESCE(content, ''),
                 COALESCE(attachment_id, ''), created_at / 300000
      )
    ''');
  }

  Future<int> insertMessage(LocalMessage msg, {String? sessionId}) async {
    final d = await db;
    return d.insert('messages', msg.toMap()..['session_id'] = sessionId);
  }

  /// 插入 bot 文本消息,若近 5 分钟内已存在相同内容(!is_from_me)则跳过。
  /// 防止 bot 文本回复被持久化两次(complete 与 end 双触发、或重连重投递时
  /// 各用不同毫秒的 createdAt,普通 upsert 按 created_at 撞不上,故用内容+时间窗去重)。
  ///
  /// 用 transaction 包裹 query+insert:sqflite 在 plugin 层串行化事务,第二个
  /// 事务的 query 必在第一个 commit 后才执行,从而能查到对方刚插入的行并跳过,
  /// 消除并发双写竞态(_handleEvent 不 await 缓存写入导致的并发)。
  Future<void> upsertBotText(LocalMessage msg, {String? sessionId}) async {
    final d = await db;
    await d.transaction((txn) async {
      final rows = await txn.query(
        'messages',
        where:
            'is_from_me = 0 AND content = ? AND created_at > ? AND session_id IS ?',
        whereArgs: [
          msg.content ?? '',
          msg.createdAt - 300000,
          sessionId,
        ],
        limit: 1,
      );
      if (rows.isEmpty) {
        await txn.insert('messages', msg.toMap()..['session_id'] = sessionId);
      }
    });
  }

  /// 是否已存在该 attachment_id 的消息。用于 attachment_saved 新建分支,
  /// 避免服务端未先发 raw 占位、只发 saved 时重复创建同一条媒体气泡。
  Future<bool> hasAttachmentId(String id, {String? sessionId}) async {
    final d = await db;
    final rows = await d.query('messages',
        where: 'attachment_id = ? AND session_id IS ?',
        whereArgs: [id, sessionId],
        limit: 1);
    return rows.isNotEmpty;
  }

  /// Insert or update by created_at. Used for media messages whose state mutates
  /// over time (uploading → sent/error; attachment_id arriving later via events):
  /// we persist on first appearance and UPDATE the same row on subsequent changes.
  ///
  /// 用 transaction 包裹 query+insert/update:sqflite 在 plugin 层串行化事务,
  /// bot 一条媒体的 raw 事件与 attachment_saved 事件各自发起一次 upsert(因
  /// _handleEvent 不 await 而并发),第二个事务的 query 必在第一个 commit 后
  /// 才执行 → 能查到对方刚插入的行 → 改为 UPDATE 同一行,而非再 INSERT 一行。
  /// 不加事务时两次 query 都赶在对方 insert 前完成、都判空、都 insert → 落两行。
  Future<void> upsert(LocalMessage msg, {String? sessionId}) async {
    final d = await db;
    await d.transaction((txn) async {
      final rows = await txn.query('messages',
          where: 'created_at = ? AND session_id IS ?',
          whereArgs: [msg.createdAt, sessionId],
          limit: 1);
      if (rows.isEmpty) {
        await txn.insert('messages', msg.toMap()..['session_id'] = sessionId);
      } else {
        await txn.update('messages', msg.toMap()..['session_id'] = sessionId,
            where: 'id = ?', whereArgs: [rows.first['id']]);
      }
    });
  }

  /// 读取指定会话的消息。[limit] 为 null 时加载全部;返回按时间正序(最早→最新)。
  /// [sessionId] 为 null 时兼容旧调用(返回全部,不应在多会话路径使用)。
  Future<List<LocalMessage>> getMessages(
      {String? sessionId, int? limit, int offset = 0}) async {
    final d = await db;
    final rows = sessionId == null
        ? await d.query('messages', orderBy: 'created_at DESC', limit: limit, offset: offset)
        : await d.query('messages',
            where: 'session_id IS ?',
            whereArgs: [sessionId],
            orderBy: 'created_at DESC',
            limit: limit,
            offset: offset);
    return rows.map((r) => LocalMessage.fromMap(r)).toList().reversed.toList();
  }

  /// 删除指定会话的全部消息(删除会话时调用)。
  Future<void> clearSession(String sessionId) async {
    final d = await db;
    await d.delete('messages', where: 'session_id = ?', whereArgs: [sessionId]);
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
