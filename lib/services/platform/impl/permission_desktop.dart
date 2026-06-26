// lib/services/platform/impl/permission_desktop.dart
import '../permission_service.dart';

/// 桌面:麦克风权限由 OS 管,无运行时请求。永远 granted,不碰任何插件。
class DesktopPermission implements PermissionService {
  @override
  Future<bool> hasMic() async => true;
  @override
  Future<bool> requestMic() async => true;
}
