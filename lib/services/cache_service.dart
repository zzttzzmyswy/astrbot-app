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
      version: 4,
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
            created_at INTEGER NOT NULL
          )
        ''');
        await _dedupMessages(db);
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
      },
    );
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

  Future<int> insertMessage(LocalMessage msg) async {
    final d = await db;
    return d.insert('messages', msg.toMap());
  }

  /// 插入 bot 文本消息,若近 5 分钟内已存在相同内容(!is_from_me)则跳过。
  /// 防止 bot 文本回复被持久化两次(complete 与 end 双触发、或重连重投递时
  /// 各用不同毫秒的 createdAt,普通 upsert 按 created_at 撞不上)。
  ///
  /// 用 transaction 包裹 query+insert:sqflite 在 plugin 层串行化事务,第二个
  /// 事务的 query 必在第一个 commit 后才执行,从而能查到对方刚插入的行并跳过,
  /// 消除并发双写竞态(_handleEvent 不 await 缓存写入导致的并发)。
  Future<void> upsertBotText(LocalMessage msg) async {
    final d = await db;
    await d.transaction((txn) async {
      final rows = await txn.query(
        'messages',
        where: 'is_from_me = 0 AND content = ? AND created_at > ?',
        whereArgs: [msg.content ?? '', msg.createdAt - 300000],
        limit: 1,
      );
      if (rows.isEmpty) {
        await txn.insert('messages', msg.toMap());
      }
    });
  }

  /// 是否已存在该 attachment_id 的消息。用于 attachment_saved 新建分支,
  /// 避免服务端未先发 raw 占位、只发 saved 时重复创建同一条媒体气泡。
  Future<bool> hasAttachmentId(String id) async {
    final d = await db;
    final rows = await d.query('messages',
        where: 'attachment_id = ?', whereArgs: [id], limit: 1);
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
  Future<void> upsert(LocalMessage msg) async {
    final d = await db;
    await d.transaction((txn) async {
      final rows = await txn.query('messages',
          where: 'created_at = ?', whereArgs: [msg.createdAt], limit: 1);
      if (rows.isEmpty) {
        await txn.insert('messages', msg.toMap());
      } else {
        await txn.update('messages', msg.toMap(),
            where: 'id = ?', whereArgs: [rows.first['id']]);
      }
    });
  }

  /// 读取消息。[limit] 为 null 时加载全部(撤销旧版只取最新 10 条的限制);
  /// 返回按时间正序(最早→最新),供 UI 直接渲染。
  Future<List<LocalMessage>> getMessages({int? limit, int offset = 0}) async {
    final d = await db;
    final rows = await d.query('messages',
        orderBy: 'created_at DESC', limit: limit, offset: offset);
    return rows.map((r) => LocalMessage.fromMap(r)).toList().reversed.toList();
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
