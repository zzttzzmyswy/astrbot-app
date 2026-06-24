enum MessageStatus { pending, uploading, sent, error }

// 哨兵值:区分 copyWith "未传 uploadProgress"(保持旧值)与"显式传 null"(清空)。
// 用 const 类实例,才能作为命名参数的默认值(普通 Object() 不是常量)。
class _UploadProgressUnset { const _UploadProgressUnset(); }
const _uploadProgressUnset = _UploadProgressUnset();

class LocalMessage {
  final int? id;
  final String msgType; // 'text', 'voice', 'image', 'file', 'thinking'
  final String? content;
  final String? attachmentId;
  final String? localPath;   // local file path for sent images/voice / 下载后的媒体
  final bool isFromMe;
  final MessageStatus status;
  final double? uploadProgress; // 0.0..1.0 while uploading, null otherwise
  final int createdAt;
  final int? serverId; // botapi 历史行 int id（用于去重；实时落库行为 null）

  const LocalMessage({
    this.id,
    required this.msgType,
    this.content,
    this.attachmentId,
    this.localPath,
    required this.isFromMe,
    this.status = MessageStatus.pending,
    this.uploadProgress,
    required this.createdAt,
    this.serverId,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'msg_type': msgType,
    'content': content,
    'attachment_id': attachmentId,
    'local_path': localPath,
    'is_from_me': isFromMe ? 1 : 0,
    'status': status.name,
    // upload_progress 是瞬态字段(仅上传中有意义),不持久化;
    // 且 DB schema 无此列,写入会导致 INSERT 抛错、消息存不进库。
    'created_at': createdAt,
    if (serverId != null) 'server_id': serverId,
  };

  factory LocalMessage.fromMap(Map<String, dynamic> map) => LocalMessage(
    id: map['id'] as int?,
    msgType: map['msg_type'] as String,
    content: map['content'] as String?,
    attachmentId: map['attachment_id'] as String?,
    localPath: map['local_path'] as String?,
    isFromMe: (map['is_from_me'] as int) == 1,
    // Tolerate older rows that lack 'uploading'; treat any persisted
    // 'uploading' as 'error' since an interrupted upload never completes.
    status: () {
      final name = map['status'] as String?;
      if (name == 'uploading') return MessageStatus.error;
      return MessageStatus.values.byName(name ?? 'pending');
    }(),
    uploadProgress: (map['upload_progress'] as num?)?.toDouble(),
    createdAt: map['created_at'] as int,
    serverId: (map['server_id'] as num?)?.toInt(),
  );

  LocalMessage copyWith({
    int? id, String? msgType, String? content, String? attachmentId,
    String? localPath, bool? isFromMe, MessageStatus? status, int? createdAt,
    int? serverId,
    Object? uploadProgress = _uploadProgressUnset,
  }) => LocalMessage(
    id: id ?? this.id, msgType: msgType ?? this.msgType,
    content: content ?? this.content, attachmentId: attachmentId ?? this.attachmentId,
    localPath: localPath ?? this.localPath, isFromMe: isFromMe ?? this.isFromMe,
    status: status ?? this.status, createdAt: createdAt ?? this.createdAt,
    serverId: serverId ?? this.serverId,
    uploadProgress: identical(uploadProgress, _uploadProgressUnset)
        ? this.uploadProgress
        : uploadProgress as double?,
  );
}
