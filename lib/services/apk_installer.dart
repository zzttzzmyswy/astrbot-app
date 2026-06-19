// lib/services/apk_installer.dart
import 'package:flutter/services.dart';

/// 通过原生 MethodChannel 触发系统 APK 安装界面。
/// Android 侧用 FileProvider 暴露下载好的 APK,再以 ACTION_VIEW +
/// application/vnd.android.package-archive 拉起安装器。
class ApkInstaller {
  static const _channel = MethodChannel('top.zztweb.astrbot/install');

  /// [apkPath] 为本地绝对路径。调用后系统会弹出安装确认页。
  static Future<void> install(String apkPath) async {
    try {
      await _channel.invokeMethod<void>('installApk', {'path': apkPath});
    } on PlatformException catch (e) {
      throw Exception('无法启动安装: ${e.message ?? e.code}');
    }
  }
}
