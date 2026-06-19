// lib/services/update_service.dart
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../util/version.dart';

/// 从 GitHub releases 拉取的最新版本信息。
class UpdateInfo {
  final String tag;      // 'v1.1.0'
  final String version;   // '1.1.0'
  final String notes;     // release body
  final String apkUrl;    // APK 资产下载地址
  final int apkSize;      // 字节
  const UpdateInfo({
    required this.tag,
    required this.version,
    required this.notes,
    required this.apkUrl,
    required this.apkSize,
  });

  String get sizeLabel {
    if (apkSize <= 0) return '';
    final mb = apkSize / 1024 / 1024;
    return '${mb.toStringAsFixed(1)} MB';
  }
}

/// 检查更新结果。
class UpdateCheck {
  final String currentVersion;
  final UpdateInfo? latest;   // null 表示拉取失败
  final String? error;        // 失败原因
  const UpdateCheck({required this.currentVersion, this.latest, this.error});

  bool get hasUpdate =>
      latest != null && compareVersions(latest!.version, currentVersion) > 0;
}

class UpdateService {
  /// GitHub 仓库(owner/name)。公开仓库,未认证调用(60次/小时,手动检查足够)。
  static const String repo = 'zzttzzmyswy/astrbot-app';
  static const String _apiBase =
      'https://api.github.com/repos/zzttzzmyswy/astrbot-app/releases/latest';

  Future<String> currentVersion() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  Future<UpdateCheck> check() async {
    final current = await currentVersion();
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        headers: {'Accept': 'application/vnd.github+json'},
      ));
      final res = await dio.get<dynamic>(_apiBase);
      if (res.statusCode != 200 || res.data is! Map) {
        return UpdateCheck(
            currentVersion: current, error: 'GitHub 接口异常: HTTP ${res.statusCode}');
      }
      final json = res.data as Map;
      final tag = (json['tag_name'] as String?)?.trim() ?? '';
      final version = tag.isEmpty ? '' : (tag.startsWith('v') ? tag.substring(1) : tag);
      final notes = (json['body'] as String?) ?? '';
      // 取第一个 .apk 资产(本次 release 命名 app-release.apk)。
      String apkUrl = '';
      int apkSize = 0;
      final assets = (json['assets'] as List?) ?? const [];
      for (final a in assets) {
        if (a is Map) {
          final name = (a['name'] as String?) ?? '';
          if (name.toLowerCase().endsWith('.apk')) {
            apkUrl = (a['browser_download_url'] as String?) ?? '';
            apkSize = (a['size'] as num?)?.toInt() ?? 0;
            break;
          }
        }
      }
      if (version.isEmpty || apkUrl.isEmpty) {
        return UpdateCheck(
            currentVersion: current, error: '未找到可用安装包');
      }
      return UpdateCheck(
        currentVersion: current,
        latest: UpdateInfo(
            tag: tag, version: version, notes: notes, apkUrl: apkUrl, apkSize: apkSize),
      );
    } on DioException catch (e) {
      return UpdateCheck(currentVersion: current, error: '网络错误: ${e.type.name}');
    } catch (e) {
      return UpdateCheck(currentVersion: current, error: '检查失败: $e');
    }
  }

  /// 下载 APK 到应用私有目录,返回本地路径。[onProgress] 为 0..1。
  Future<String> download(String url,
      {void Function(double progress)? onProgress}) async {
    final dir = await getApplicationDocumentsDirectory();
    final savePath = '${dir.path}/astrbot-update.apk';
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 5),
    ));
    await dio.download(
      url,
      savePath,
      onReceiveProgress: (received, total) {
        if (total > 0) onProgress?.call((received / total).clamp(0.0, 1.0));
      },
      options: Options(responseType: ResponseType.stream),
    );
    return savePath;
  }
}
