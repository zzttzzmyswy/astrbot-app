// lib/services/platform/impl/permission_mobile.dart
import 'package:record/record.dart';
import '../permission_service.dart';

/// 移动端:用 record 包的 AudioRecorder 查询/请求麦克风权限。
class MobilePermission implements PermissionService {
  final AudioRecorder _recorder = AudioRecorder();

  @override
  Future<bool> hasMic() => _recorder.hasPermission();

  @override
  Future<bool> requestMic() async {
    // record 包的 hasPermission() 内部会触发系统权限对话框(若未授权)。
    return _recorder.hasPermission();
  }
}
