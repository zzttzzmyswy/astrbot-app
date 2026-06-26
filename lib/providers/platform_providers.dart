// lib/providers/platform_providers.dart
//
// 平台实现的注入点。Platform.is* 只在此处出现一次,其余代码面向接口。
import 'dart:io' show Platform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/platform/keep_alive_service.dart';
import '../services/platform/permission_service.dart';
import '../services/platform/update_applier.dart';
import '../services/platform/impl/keep_alive_mobile.dart';
import '../services/platform/impl/keep_alive_desktop.dart';
import '../services/platform/impl/permission_mobile.dart';
import '../services/platform/impl/permission_desktop.dart';
import '../services/platform/impl/update_mobile.dart';
import '../services/platform/impl/update_desktop.dart';

final keepAliveProvider = Provider<KeepAliveService>(
    (ref) => Platform.isAndroid ? MobileKeepAlive() : DesktopKeepAlive());

final permissionProvider = Provider<PermissionService>(
    (ref) => Platform.isAndroid ? MobilePermission() : DesktopPermission());

final updateApplierProvider = Provider<UpdateApplier>(
    (ref) => Platform.isAndroid ? MobileUpdateApplier() : DesktopUpdateApplier());
