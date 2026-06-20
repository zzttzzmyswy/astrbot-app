// lib/services/device_oem_service.dart
//
// 封装与原生 MainActivity(top.zztweb.astrbot/device)的 method channel,读取厂商信息
// 与打开后台白名单设置页。纯查询 + best-effort,任何失败都降级为「不引导」。
import 'package:flutter/services.dart';
import '../util/oem_whitelist.dart';

class DeviceOemService {
  const DeviceOemService();

  static const _channel = MethodChannel('top.zztweb.astrbot/device');

  /// 读取厂商信息;失败返回 unknown(不引导)。
  Future<OemInfo> getInfo() async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>('getOemInfo');
      if (map == null) return OemInfo.unknown;
      return OemInfo(
        manufacturer: (map['manufacturer'] as String?) ?? '',
        brand: (map['brand'] as String?) ?? '',
        hasPowerGenie: (map['hasPowerGenie'] as bool?) ?? false,
      );
    } on PlatformException {
      return OemInfo.unknown;
    } on MissingPluginException {
      return OemInfo.unknown;
    }
  }

  /// 打开后台白名单设置页(荣耀/华为电源管理;回退到本应用系统详情页)。
  /// 返回是否成功打开。
  Future<bool> openAppLaunchSettings() async {
    try {
      return (await _channel.invokeMethod<bool>('openAppLaunchSettings')) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
