// lib/services/platform/update_applier.dart
//
// 更新「最后一步」抽象:检测+下载在 UpdateService(平台无关),本接口只负责
// 安装/打开。移动端下载完 APK 调原生 installApk;桌面端直接 url_launcher
// 打开 GitHub release 资产页(不在应用内下载)。
import '../update_service.dart';

abstract class UpdateApplier {
  /// 按钮文案。移动端「立即更新」,桌面端「打开下载页」。
  String get actionLabel;

  /// 执行更新。移动端:onProgress 报告下载进度 0..1;桌面端忽略 onProgress,
  /// 直接开浏览器(几乎瞬时返回)。
  Future<void> apply(UpdateInfo info, {void Function(double p)? onProgress});
}
