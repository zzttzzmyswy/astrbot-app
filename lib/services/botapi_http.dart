// lib/services/botapi_http.dart
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';
import 'package:path_provider/path_provider.dart';
import '../models/history_row.dart';

/// 规整 serverUrl 为 botapi base：保证以 /api/v1/botapi 结尾、无尾斜杠。
String botapiBase(String serverUrl) {
  var s = serverUrl.trim();
  if (s.isEmpty) return s;
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.endsWith('/api/v1/botapi')) return s;
  return '$s/api/v1/botapi';
}

class UploadResult {
  final String fileId;
  final String name;
  final String mimeType;
  final int size;
  const UploadResult({
    required this.fileId,
    required this.name,
    required this.mimeType,
    required this.size,
  });
}

/// botapi 无状态 REST 客户端。给定 (serverUrl, token)。
class BotApiHttp {
  final String serverUrl;
  final String token;
  BotApiHttp({required this.serverUrl, required this.token});

  String get _base => botapiBase(serverUrl);
  Map<String, String> get _authHeaders => {'Authorization': 'Bearer $token'};

  /// 校验 token。true=有效；false=无效(401)或不可达。
  Future<bool> auth() async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 12),
      ));
      final res = await dio.post('$_base/auth',
          data: {'token': token},
          options: Options(headers: {'Content-Type': 'application/json'}));
      return res.statusCode == 200;
    } on DioException catch (e) {
      // 401 = token 无效；网络不可达也返回 false（调用方据此提示检查地址/token）
      if (e.response?.statusCode == 401) return false;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 发消息。返回 message_id；失败返回 null。
  Future<String?> sendMessage({String? text, List<String>? fileIds}) async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ));
      final res = await dio.post('$_base/message',
          data: {
            if (text != null && text.isNotEmpty) 'text': text,
            if (fileIds != null && fileIds.isNotEmpty) 'file_ids': fileIds,
          },
          options: Options(headers: {..._authHeaders, 'Content-Type': 'application/json'}));
      if (res.statusCode == 200) {
        return (res.data is Map) ? (res.data as Map)['message_id'] as String? : null;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 上传文件。返回 UploadResult；失败 null。
  Future<UploadResult?> uploadFile(File file, String contentType,
      {void Function(int sent, int total)? onProgress}) async {
    try {
      final filename = file.path.split('/').last;
      final dio = Dio(BaseOptions(
        baseUrl: _base,
        connectTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 120),
        receiveTimeout: const Duration(seconds: 60),
      ));
      final form = FormData.fromMap({
        'file': await MultipartFile.fromFile(file.path,
            filename: filename, contentType: MediaType.parse(contentType)),
      });
      final res = await dio.post('/upload',
          data: form, options: Options(headers: _authHeaders), onSendProgress: onProgress);
      if (res.statusCode == 200 && res.data is Map) {
        final m = res.data as Map<String, dynamic>;
        return UploadResult(
          fileId: m['file_id'] as String,
          name: m['name'] as String,
          mimeType: (m['mime_type'] as String?) ?? 'application/octet-stream',
          size: (m['size'] as num).toInt(),
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 拉历史。since/before 为整数 id（可空）。
  Future<HistoryResult> fetchHistory({int? since, int? before, int limit = 200}) async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ));
      final q = <String, dynamic>{'limit': limit};
      if (since != null) q['since'] = since;
      if (before != null) q['before'] = before;
      final res = await dio.get('$_base/history',
          queryParameters: q, options: Options(headers: _authHeaders));
      if (res.statusCode == 200 && res.data is Map) {
        final m = res.data as Map<String, dynamic>;
        final list = (m['messages'] as List?) ?? [];
        return HistoryResult(
          messages: list
              .map((e) => HistoryRow.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList(),
          hasMore: (m['has_more'] as bool?) ?? false,
        );
      }
      return const HistoryResult(messages: [], hasMore: false);
    } catch (_) {
      return const HistoryResult(messages: [], hasMore: false);
    }
  }

  /// 下载媒体 URL（单次有效，免认证）。写入 attachments 目录，返回本地 File。
  Future<File?> downloadByUrl(String url) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${dir.path}/attachments');
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final tail = Uri.parse(url).pathSegments.last;
      final name = (tail.isEmpty
              ? DateTime.now().millisecondsSinceEpoch.toString()
              : tail)
          .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final path = '${cacheDir.path}/$name';
      final existing = File(path);
      if (await existing.exists() && await existing.length() > 0) return existing;
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ));
      final res = await dio.get<List<int>>(url, options: Options(responseType: ResponseType.bytes));
      final ct = res.headers.value('content-type') ?? '';
      if (res.statusCode != 200 || ct.contains('application/json')) return null;
      final bytes = res.data ?? const <int>[];
      if (bytes.isEmpty) return null;
      await existing.writeAsBytes(bytes);
      return existing;
    } catch (_) {
      return null;
    }
  }

  /// 清理 7 天前的附件缓存（botapi 媒体单次有效，本地缓存即下载文件）。
  static Future<void> cleanOldCache() async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${dir.path}/attachments');
    if (!await cacheDir.exists()) return;
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    await for (final e in cacheDir.list()) {
      if (e is File) {
        final stat = await e.stat();
        if (stat.modified.isBefore(cutoff)) await e.delete();
      }
    }
  }
}
