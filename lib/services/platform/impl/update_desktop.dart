// lib/services/platform/impl/update_desktop.dart
import 'package:url_launcher/url_launcher.dart';
import '../update_applier.dart';
import '../../update_service.dart';

/// 桌面:不在应用内下载,直接用系统默认浏览器打开 APK 资产页(GitHub)。
class DesktopUpdateApplier implements UpdateApplier {
  @override
  String get actionLabel => '打开下载页';

  @override
  Future<void> apply(UpdateInfo info, {void Function(double p)? onProgress}) async {
    final url = info.apkUrl;
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
