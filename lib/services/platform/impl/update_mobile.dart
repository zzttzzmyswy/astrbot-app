// lib/services/platform/impl/update_mobile.dart
//
// 移动端:下载 APK(复用 UpdateService.download)+ 原生 installApk MethodChannel。
// 搬迁自原 apk_installer.dart,行为不变。
import 'package:flutter/services.dart';
import '../update_applier.dart';
import '../../update_service.dart';

class MobileUpdateApplier implements UpdateApplier {
  static const _channel = MethodChannel('top.zztweb.astrbot/install');

  final UpdateService _svc = UpdateService();

  @override
  String get actionLabel => '立即更新';

  @override
  Future<void> apply(UpdateInfo info, {void Function(double p)? onProgress}) async {
    final path = await _svc.download(info.apkUrl, onProgress: onProgress ?? (_) {});
    try {
      await _channel.invokeMethod<void>('installApk', {'path': path});
    } on PlatformException catch (e) {
      throw Exception('无法启动安装: ${e.message ?? e.code}');
    }
  }
}
