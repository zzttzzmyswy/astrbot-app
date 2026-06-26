// lib/services/platform/permission_service.dart
//
// 麦克风权限抽象:移动端走 record.hasPermission + 请求,桌面端永远 granted
// (桌面由 OS/PulseAudio 管,无运行时请求 API;permission_handler 无 Linux 实现)。
abstract class PermissionService {
  Future<bool> hasMic();
  Future<bool> requestMic();
}
