// lib/services/file_service.dart
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';
import 'package:path_provider/path_provider.dart';
import '../util/retry.dart';

class FileService {
  final String serverUrl;
  final String apiKey;

  FileService({required this.serverUrl, required this.apiKey});

  Future<Map<String, dynamic>> uploadFile(
    File file,
    String contentType, {
    void Function(int sent, int total)? onProgress,
  }) async {
    // Dio's onSendProgress reports bytes actually transmitted to the socket,
    // so it reflects real network upload speed (not just file-read speed).
    // It only paints now because the chat screen rebuilds on message-list
    // identity changes (in-place uploadProgress updates).
    try {
      final filename = file.path.split('/').last;
      final dio = Dio(BaseOptions(
        baseUrl: serverUrl,
        connectTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 120),
        receiveTimeout: const Duration(seconds: 60),
      ));
      final form = FormData.fromMap({
        'file': await MultipartFile.fromFile(
          file.path,
          filename: filename,
          contentType: MediaType.parse(contentType),
        ),
      });
      final response = await withRetry(
        () => dio.post(
          '/api/v1/file',
          data: form,
          options: Options(headers: {'X-API-Key': apiKey}),
          onSendProgress: onProgress,
        ),
        isTransient: isTransientDioError,
        maxAttempts: 3,
        delayFor: (i) => Duration(milliseconds: 1000 << i),
      );
      final json = response.data is Map ? response.data as Map<String, dynamic>
          : jsonDecode(response.data.toString()) as Map<String, dynamic>;
      if (json['status'] == 'error') {
        return {'status': 'error', 'message': json['message'] ?? '上传失败'};
      }
      return (json['data'] as Map<String, dynamic>?) ?? {};
    } on DioException catch (e) {
      return {'status': 'error', 'message': '上传异常: ${e.message ?? e.type.name}'};
    } catch (e) {
      return {'status': 'error', 'message': '上传异常: $e'};
    }
  }

  Future<File?> downloadAttachment(String attachmentId) async {
    if (attachmentId.isEmpty) return null;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${dir.path}/attachments');
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      final filePath = '${cacheDir.path}/$attachmentId';
      final file = File(filePath);
      if (await file.exists() && await file.length() > 0) return file;

      final dio = Dio(BaseOptions(
        baseUrl: serverUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ));
      final response = await withRetry(
        () => dio.get<List<int>>(
          '/api/v1/file',
          queryParameters: {'attachment_id': attachmentId},
          options: Options(headers: {'X-API-Key': apiKey}, responseType: ResponseType.bytes),
        ),
        isTransient: isTransientDioError,
        maxAttempts: 3,
        delayFor: (i) => Duration(milliseconds: 1000 << i),
      );

      // The open API returns HTTP 200 with a JSON error body (e.g.
      // {"status":"error","message":"Attachment not found"}) when an
      // attachment_id can't be resolved. Guard against caching that error
      // payload as if it were file bytes — it would poison the cache and
      // break rendering forever.
      final contentType = response.headers.value('content-type') ?? '';
      if (response.statusCode != 200 || contentType.contains('application/json')) {
        return null;
      }
      final bytes = response.data ?? const <int>[];
      if (bytes.isEmpty) return null;
      await file.writeAsBytes(bytes);
      return file;
    } catch (_) {}
    return null;
  }

  Future<String> saveToDownloads(String attachmentId, String filename) async {
    final file = await downloadAttachment(attachmentId);
    if (file == null) throw Exception('文件下载失败');
    final downloadDir = Directory('/storage/emulated/0/Download/AstrBot');
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    final dest = File('${downloadDir.path}/$filename');
    await file.copy(dest.path);
    return dest.path;
  }

  Future<void> cleanOldCache() async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${dir.path}/attachments');
    if (!await cacheDir.exists()) return;

    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    await for (final entity in cacheDir.list()) {
      if (entity is File) {
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete();
        }
      }
    }
  }
}
