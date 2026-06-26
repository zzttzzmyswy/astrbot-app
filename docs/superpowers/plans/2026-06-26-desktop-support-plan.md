# 桌面支持第一步（Windows + Linux）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 app 在 Windows/Linux 桌面能构建、运行、聊天，移动端专属能力安全降级，Android 不回归。

**Architecture:** 平台抽象层（方案 B）——3 个随平台变化的能力（KeepAlive / Permission / UpdateApplier）抽成 Riverpod 注入接口，各一对 mobile/desktop 实现，`Platform.is*` 只出现在 `platform_providers.dart` 一处。sqflite 桌面走 FFI；`WithForegroundTask` 按平台二选一；宽窗居中列。详见 `docs/superpowers/specs/2026-06-26-desktop-support-design.md`。

**Tech Stack:** Flutter 3.38 / Dart 3.2 / Riverpod 2.5 / sqflite_common_ffi / flutter_foreground_task / record / audioplayers / url_launcher / dio。

---

## Task 1: 加 sqflite_common_ffi 依赖 + 桌面 FFI init

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/main.dart`

- [ ] **Step 1: 加依赖**

`pubspec.yaml` dependencies 块，在 `sqflite: ^2.3.0` 下一行加：

```yaml
  sqflite_common_ffi: ^2.3.3
```

- [ ] **Step 2: pub get**

Run: `flutter pub get`
Expected: 解析成功，新增 sqflite_common_ffi 相关包。

- [ ] **Step 3: main.dart FFI init**

`lib/main.dart` 顶部 import 区加：

```dart
import 'dart:io' show Platform;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
```

`main()` 函数体，在 `WidgetsFlutterBinding.ensureInitialized();` 之后、`initKeepAliveService();` 之前插入：

```dart
  // 桌面(sqflite 无默认 factory)走 FFI;移动端用原生 factory 不变。
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
```

- [ ] **Step 4: 验证 analyze**

Run: `flutter analyze lib/main.dart`
Expected: 无 error（info/warning 可有）。

- [ ] **Step 5: 验证 Android 不回归**

Run: `flutter build apk --debug`
Expected: 构建成功（FFI 分支 Android 不触发）。

- [ ] **Step 6: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/main.dart
git commit -m "feat(desktop): sqflite 桌面 FFI init"
```

---

## Task 2: KeepAlive 抽象（接口 + mobile + desktop 实现）

**Files:**
- Create: `lib/services/platform/keep_alive_service.dart`
- Create: `lib/services/platform/impl/keep_alive_mobile.dart`
- Create: `lib/services/platform/impl/keep_alive_desktop.dart`
- Create: `test/services/platform/keep_alive_desktop_test.dart`
- Delete: `lib/services/foreground_service.dart`（内容并入 mobile impl）

- [ ] **Step 1: 写接口**

`lib/services/platform/keep_alive_service.dart`：

```dart
// lib/services/platform/keep_alive_service.dart
//
// 前台保活抽象:移动端用 flutter_foreground_task 常驻通知保持进程存活,
// 桌面端 no-op(窗口开即活,关即断)。调用点面向接口,不知平台。
abstract class KeepAliveService {
  /// 启动时调一次(注册通知渠道等)。幂等。
  Future<void> init();

  /// 启动保活(幂等,best-effort,失败不抛)。
  Future<void> start();

  /// 停止保活。
  Future<void> stop();
}
```

- [ ] **Step 2: 写 desktop 实现**

`lib/services/platform/impl/keep_alive_desktop.dart`：

```dart
// lib/services/platform/impl/keep_alive_desktop.dart
import '../keep_alive_service.dart';

/// 桌面 no-op:窗口在则进程在,无需前台服务。绝不触碰 flutter_foreground_task
/// (该包桌面无实现,碰了会 MissingPluginError)。
class DesktopKeepAlive implements KeepAliveService {
  @override
  Future<void> init() async {}
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}
```

- [ ] **Step 3: 写 desktop 实现单测**

`test/services/platform/keep_alive_desktop_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/services/platform/impl/keep_alive_desktop.dart';

void main() {
  test('DesktopKeepAlive 全 no-op 且不抛', () async {
    final s = DesktopKeepAlive();
    await s.init();
    await s.start();
    await s.stop();
    expect(true, true); // 到这里没抛即通过
  });
}
```

- [ ] **Step 4: 跑测验证通过**

Run: `flutter test test/services/platform/keep_alive_desktop_test.dart`
Expected: PASS。

- [ ] **Step 5: 写 mobile 实现（搬迁自 foreground_service.dart）**

`lib/services/platform/impl/keep_alive_mobile.dart`：

```dart
// lib/services/platform/impl/keep_alive_mobile.dart
//
// 移动端保活:flutter_foreground_task v8 常驻通知。搬迁自原 foreground_service.dart,
// 行为不变。keepAliveStartCallback 必须顶层 + @pragma('vm:entry-point') 防 tree-shaking。
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../keep_alive_service.dart';

class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

@pragma('vm:entry-point')
void keepAliveStartCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}

class MobileKeepAlive implements KeepAliveService {
  @override
  Future<void> init() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'astrbot_keepalive',
        channelName: 'Bot助手 后台运行',
        channelDescription: '保持与服务器的连接，防止丢失消息',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  @override
  Future<void> start() async {
    try {
      await FlutterForegroundTask.requestNotificationPermission();
      if (await FlutterForegroundTask.isRunningService) return;
      final result = await FlutterForegroundTask.startService(
        notificationTitle: 'Bot助手 正在运行',
        notificationText: '保持连接以接收新消息',
        callback: keepAliveStartCallback,
      );
      final _ = result; // ServiceRequestSuccess | Failure,忽略
    } catch (_) {
      // best-effort,绝不因保活崩 app。
    }
  }

  @override
  Future<void> stop() async {
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }
}
```

- [ ] **Step 6: 删除旧文件**

Run: `rm lib/services/foreground_service.dart`

- [ ] **Step 7: 修复引用**

`lib/main.dart`：
- 删除 import `import 'services/foreground_service.dart';`
- 删除 `main()` 中的 `initKeepAliveService();` 一行（init 改由 Task 6 在 chat_screen 经 provider 调）。

`lib/screens/chat_screen.dart`：
- 暂时**保留** `import '../services/foreground_service.dart';` 与 `startKeepAliveService();`（chat_screen.dart:116）——Task 6 会把它改为经 provider。本任务只删 main 的 init + foreground_service.dart 文件。删除文件后 chat_screen 仍引用会编译断,故本步**先不删 foreground_service.dart**,改为在 Task 6 替换 chat_screen 引用后再删。

修正:本 Step 7 只改 main.dart(删 import + init 行)。foreground_service.dart 的删除推迟到 Task 6 Step 4(chat_screen 引用替换后)。

- [ ] **Step 8: 验证 analyze + 测试**

Run: `flutter analyze lib/services/platform/ lib/main.dart && flutter test test/services/platform/keep_alive_desktop_test.dart`
Expected: 无 error，desktop 测试 PASS。（注:foreground_service.dart 仍在,chat_screen 仍引用,编译不断。）

- [ ] **Step 9: Commit**

```bash
git add lib/services/platform/ lib/main.dart test/services/platform/keep_alive_desktop_test.dart
git commit -m "feat(desktop): KeepAlive 抽象 + mobile/desktop 实现"
```

（foreground_service.dart 在 Task 6 删除,本任务不 git rm。）

---

## Task 3: Permission 抽象（接口 + mobile + desktop 实现）

**Files:**
- Create: `lib/services/platform/permission_service.dart`
- Create: `lib/services/platform/impl/permission_mobile.dart`
- Create: `lib/services/platform/impl/permission_desktop.dart`
- Create: `test/services/platform/permission_desktop_test.dart`

- [ ] **Step 1: 写接口**

`lib/services/platform/permission_service.dart`：

```dart
// lib/services/platform/permission_service.dart
//
// 麦克风权限抽象:移动端走 record.hasPermission + 请求,桌面端永远 granted
// (桌面由 OS/PulseAudio 管,无运行时请求 API;permission_handler 无 Linux 实现)。
abstract class PermissionService {
  Future<bool> hasMic();
  Future<bool> requestMic();
}
```

- [ ] **Step 2: 写 desktop 实现**

`lib/services/platform/impl/permission_desktop.dart`：

```dart
import '../permission_service.dart';

/// 桌面:麦克风权限由 OS 管,无运行时请求。永远 granted,不碰任何插件。
class DesktopPermission implements PermissionService {
  @override
  Future<bool> hasMic() async => true;
  @override
  Future<bool> requestMic() async => true;
}
```

- [ ] **Step 3: 写 desktop 单测**

`test/services/platform/permission_desktop_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/services/platform/impl/permission_desktop.dart';

void main() {
  test('DesktopPermission 永远 granted', () async {
    final p = DesktopPermission();
    expect(await p.hasMic(), true);
    expect(await p.requestMic(), true);
  });
}
```

- [ ] **Step 4: 跑测**

Run: `flutter test test/services/platform/permission_desktop_test.dart`
Expected: PASS。

- [ ] **Step 5: 写 mobile 实现**

`lib/services/platform/impl/permission_mobile.dart`：

```dart
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
```

- [ ] **Step 6: 验证 analyze**

Run: `flutter analyze lib/services/platform/`
Expected: 无 error。

- [ ] **Step 7: Commit**

```bash
git add lib/services/platform/ test/services/platform/permission_desktop_test.dart
git commit -m "feat(desktop): Permission 抽象 + mobile/desktop 实现"
```

---

## Task 4: UpdateApplier 抽象（接口 + mobile + desktop 实现）

**Files:**
- Create: `lib/services/platform/update_applier.dart`
- Create: `lib/services/platform/impl/update_mobile.dart`
- Create: `lib/services/platform/impl/update_desktop.dart`
- Create: `test/services/platform/update_desktop_test.dart`
- Delete: `lib/services/apk_installer.dart`（内容并入 mobile impl）

- [ ] **Step 1: 写接口**

`lib/services/platform/update_applier.dart`：

```dart
// lib/services/platform/update_applier.dart
//
// 更新「最后一步」抽象:检测+下载在 UpdateService(平台无关),本接口只负责
// 安装/打开。移动端下载完 APK 调原生 installApk;桌面端直接 url_launcher
// 打开 GitHub release 资产页(不在应用内下载)。
import '../../services/update_service.dart';

abstract class UpdateApplier {
  /// 按钮文案。移动端「立即更新」,桌面端「打开下载页」。
  String get actionLabel;

  /// 执行更新。移动端:onProgress 报告下载进度 0..1;桌面端忽略 onProgress,
  /// 直接开浏览器(几乎瞬时返回)。
  Future<void> apply(UpdateInfo info, {void Function(double p)? onProgress});
}
```

- [ ] **Step 2: 写 desktop 实现**

`lib/services/platform/impl/update_desktop.dart`：

```dart
import 'package:url_launcher/url_launcher.dart';
import '../update_applier.dart';
import '../../services/update_service.dart';

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
```

- [ ] **Step 3: 写 desktop 单测**

`test/services/platform/update_desktop_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/services/platform/impl/update_desktop.dart';
import 'package:astrbot_app/services/update_service.dart';

void main() {
  group('DesktopUpdateApplier', () {
    test('actionLabel 为「打开下载页」', () {
      expect(DesktopUpdateApplier().actionLabel, '打开下载页');
    });

    test('空 apkUrl 不抛、不打开', () async {
      final a = DesktopUpdateApplier();
      const info = UpdateInfo(
          tag: '', version: '', notes: '', apkUrl: '', apkSize: 0);
      await a.apply(info); // 不应抛
    });

    test('非 http(s) scheme 不打开', () async {
      final a = DesktopUpdateApplier();
      const info = UpdateInfo(
          tag: '', version: '', notes: '', apkUrl: 'javascript:alert(1)', apkSize: 0);
      await a.apply(info); // 不应抛,不应打开浏览器
    });
  });
}
```

- [ ] **Step 4: 跑测**

Run: `flutter test test/services/platform/update_desktop_test.dart`
Expected: PASS。（注:launchUrl 在测试环境未绑定 platform channel 会抛 MissingPluginException,但前两个用例 url 为空/scheme 非法,在 launchUrl 调用前 return,不会触发;第三个 scheme 非法也 return。故三例都不触达 launchUrl。）

- [ ] **Step 5: 写 mobile 实现（搬迁自 apk_installer.dart）**

`lib/services/platform/impl/update_mobile.dart`：

```dart
// lib/services/platform/impl/update_mobile.dart
//
// 移动端:下载 APK(复用 UpdateService.download)+ 原生 installApk MethodChannel。
// 搬迁自原 apk_installer.dart,行为不变。
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../update_applier.dart';
import '../../services/update_service.dart';

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
```

- [ ] **Step 6: 删除旧文件**

Run: `rm lib/services/apk_installer.dart`

- [ ] **Step 7: 验证 analyze + 测试**

Run: `flutter analyze lib/services/platform/ && flutter test test/services/platform/update_desktop_test.dart`
Expected: 无 error，测试 PASS。

- [ ] **Step 8: Commit**

```bash
git add lib/services/platform/ test/services/platform/update_desktop_test.dart
git rm lib/services/apk_installer.dart
git commit -m "feat(desktop): UpdateApplier 抽象 + mobile/desktop 实现"
```

---

## Task 5: platform_providers（Riverpod 注入）

**Files:**
- Create: `lib/providers/platform_providers.dart`

- [ ] **Step 1: 写 providers**

`lib/providers/platform_providers.dart`：

```dart
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
```

- [ ] **Step 2: 验证 analyze**

Run: `flutter analyze lib/providers/platform_providers.dart`
Expected: 无 error。

- [ ] **Step 3: Commit**

```bash
git add lib/providers/platform_providers.dart
git commit -m "feat(desktop): platform_providers 注入点"
```

---

## Task 6: 接入 keepAliveProvider + WithForegroundTask 平台二选一

**Files:**
- Modify: `lib/screens/chat_screen.dart`（chat_screen.dart:116 `startKeepAliveService()` 调用点）
- Modify: `lib/main.dart`
- Delete: `lib/services/foreground_service.dart`

- [ ] **Step 1: chat_screen 经 provider 调保活**

`lib/screens/chat_screen.dart`：
- 顶部 import 删 `import '../services/foreground_service.dart';`,加 `import '../providers/platform_providers.dart';`
- chat_screen.dart:116 处 `startKeepAliveService();` 替换为:

```dart
    final ka = ref.read(keepAliveProvider);
    await ka.init();
    await ka.start();
```

（_ChatScreenState 是 ConsumerState,可读 ref;116 行所在方法若是 async 直接 await,否则包 `() async { ... }()`。init 幂等可重复调。）

- [ ] **Step 2: 删除 foreground_service.dart**

Run: `rm lib/services/foreground_service.dart`
（main 的引用 T2 已删,chat_screen 引用本 Step 1 已删,可安全删。）

- [ ] **Step 3: main.dart WithForegroundTask 平台二选一**

`lib/main.dart`：
- 顶部 import 加 `import 'dart:io' show Platform;` 和 `import 'package:flutter_foreground_task/flutter_foreground_task.dart';`
- `AstrBotApp.build` 末尾,把 `return MaterialApp(...)` 改为先赋局部变量再二选一:

```dart
    final app = MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: <原 theme 不变>,
      darkTheme: <原 darkTheme 不变>,
      themeMode: themeMode,
      home: asyncConfig.when(
        data: (isConfigured) => isConfigured ? const ChatScreen() : const SetupScreen(),
        loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
        error: (_, __) => const SetupScreen(),
      ),
    );
    // WithForegroundTask 仅 Android 有实现,桌面碰了 MissingPluginError。
    return Platform.isAndroid ? WithForegroundTask(child: app) : app;
```

（把原 return 的 MaterialApp 整体改为赋给 `app`,theme/darkTheme/home 内容原样搬入。）

- [ ] **Step 4: 验证 analyze**

Run: `flutter analyze lib/main.dart lib/screens/chat_screen.dart`
Expected: 无 error（foreground_service.dart 已删,无残留引用）。

- [ ] **Step 5: 验证 Android 不回归**

Run: `flutter build apk --debug`
Expected: 构建成功。

- [ ] **Step 6: Commit**

```bash
git add lib/screens/chat_screen.dart lib/main.dart
git rm lib/services/foreground_service.dart
git commit -m "feat(desktop): 保活经 keepAliveProvider + WithForegroundTask 平台二选一"
```

---

## Task 7: settings_screen 更新按钮经 UpdateApplier

**Files:**
- Modify: `lib/screens/settings_screen.dart`

- [ ] **Step 1: 找现有调用点**

Run: `grep -n "ApkInstaller\|_downloadAndInstall\|立即更新\|actionLabel\|UpdateService" lib/screens/settings_screen.dart`
确认 `_downloadAndInstall` 方法与按钮文案「立即更新」位置。

- [ ] **Step 2: 引入 provider**

`lib/screens/settings_screen.dart` 顶部 import 加:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/platform_providers.dart';
```

（若文件已 ConsumerStatefulWidget 且已 import riverpod,只加 platform_providers。）

- [ ] **Step 3: 改 _downloadAndInstall 经 applier**

把原:

```dart
  Future<void> _downloadAndInstall() async {
    final info = _check?.latest;
    if (info == null) return;
    setState(() { _s = _S.downloading; _progress = 0; });
    try {
      final path = await _svc.download(info.apkUrl, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() => _s = _S.installing);
      await ApkInstaller.install(path);
    } catch (e) {
      if (mounted) {
        _check = UpdateCheck(currentVersion: _check?.currentVersion ?? '', error: '更新失败: $e');
        setState(() => _s = _S.error);
      }
    }
  }
```

改为:

```dart
  Future<void> _downloadAndInstall() async {
    final info = _check?.latest;
    if (info == null) return;
    final applier = ref.read(updateApplierProvider);
    setState(() { _s = _S.downloading; _progress = 0; });
    try {
      await applier.apply(info, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() => _s = _S.installing);
    } catch (e) {
      if (mounted) {
        _check = UpdateCheck(currentVersion: _check?.currentVersion ?? '', error: '更新失败: $e');
        setState(() => _s = _S.error);
      }
    }
  }
```

（注:mobile applier 内部 download+install,install 在 apply 内完成,故 apply 返回后无需再 ApkInstaller.install;桌面 applier 直接开浏览器,apply 瞬时返回,_S.installing 状态闪一下即终。可接受。）

- [ ] **Step 4: 按钮文案用 applier.actionLabel**

找到按钮处 `const Text('立即更新')`,改为:

```dart
Text(ref.watch(updateApplierProvider).actionLabel)
```

- [ ] **Step 5: 清理旧 import**

删除 `import '../services/apk_installer.dart';`（若存在）。

- [ ] **Step 6: 验证 analyze**

Run: `flutter analyze lib/screens/settings_screen.dart`
Expected: 无 error。

- [ ] **Step 7: Commit**

```bash
git add lib/screens/settings_screen.dart
git commit -m "feat(desktop): 更新按钮经 UpdateApplier(桌面开浏览器)"
```

---

## Task 8: audio_service 权限经 PermissionService

**Files:**
- Modify: `lib/services/audio_service.dart`

- [ ] **Step 1: 看现状**

Run: `grep -n "hasPermission\|_recorder\|AudioRecorder" lib/services/audio_service.dart`

- [ ] **Step 2: 改 hasPermission 经 provider**

`AudioService` 现为普通类(`AudioService`),非 Riverpod。两种选择:(a) 把 PermissionService 作为构造参数注入;(b) AudioService 改 Riverpod provider。选 (a) 最小改动:

`lib/services/audio_service.dart`:
- import 加 `import 'package:flutter_riverpod/flutter_riverpod.dart';` 和 `import '../platform/permission_service.dart';` 和 `import '../providers/platform_providers.dart';`
- `AudioService` 构造改为接收 `PermissionService`:

```dart
class AudioService {
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  String? _recordingPath;
  final PermissionService _permission;

  AudioService(this._permission);

  Future<bool> hasPermission() async => _permission.hasMic();
  // startRecording 前若需请求,调 _permission.requestMic()
  Future<void> startRecording() async {
    if (!await _permission.requestMic()) return; // 未授权不录
    final dir = await getTemporaryDirectory();
    _recordingPath = '${dir.path}/draft_record.wav';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.wav), path: _recordingPath!);
  }
  // ...其余不动
}
```

（确认 `startRecording` 原签名与返回,尽量只增 `requestMic` 守卫,不改其余。）

- [ ] **Step 3: 调用点注入**

Run: `grep -rn "AudioService(" lib/`
所有 `AudioService()` 调用改为 `AudioService(ref.read(permissionProvider))`。若调用点在非 Consumer 处,改为从最近 Consumer 拿 ref,或把 AudioService 本身包成 Riverpod provider。优先:在 chat_provider 内 `final audio = AudioService(ref.read(permissionProvider));` 持有。

- [ ] **Step 4: 验证 analyze**

Run: `flutter analyze lib/services/audio_service.dart`
Expected: 无 error。

- [ ] **Step 5: Commit**

```bash
git add lib/services/audio_service.dart lib/providers/chat_provider.dart
git commit -m "feat(desktop): 录音权限经 PermissionService"
```

---

## Task 9: 启用桌面 + 生成 runner + 改窗口尺寸

**Files:**
- Create: `windows/`（flutter create 生成）
- Create: `linux/`（flutter create 生成）
- Modify: `windows/runner/main.cpp`
- Modify: `linux/my_application.cc`

- [ ] **Step 1: 启用桌面平台**

Run: `flutter config --enable-windows-desktop --enable-linux-desktop`
Expected: 输出 `enable-windows-desktop: true` 与 `enable-linux-desktop: true`。

- [ ] **Step 2: 生成 runner**

Run: `flutter create --platforms=windows,linux --project-name astrbot_app .`
Expected: 生成 `windows/` 与 `linux/` 目录,无覆盖现有 lib。

- [ ] **Step 3: 改 Windows 默认窗口尺寸**

`windows/runner/main.cpp` 找到 `flutter_windows_controller.Create(...)` 附近的窗口创建,或在 `Win32` `CreateWindow` 后的 `SetWindowPos`/初始 width/height。把默认宽高改为 960×680。具体:找到形如:

```cpp
  HWND hwnd = CreateWindowW(window_class.lpszClassName, L"astrbot_app",
                            WS_OVERLAPPEDWINDOW | WS_VISIBLE, CW_USEDEFAULT,
                            CW_USEDEFAULT, 960, 680, nullptr, nullptr,
                            instance, this);
```

将宽高参数改为 `960, 680`(若原为其他值)。若无显式尺寸,在 `ShowWindow` 前加 `MoveWindow(hwnd, x, y, 960, 680, TRUE)`。

- [ ] **Step 4: 改 Linux 默认窗口尺寸**

`linux/my_application.cc` 的 `my_application_activate` 中找到 `gtk_window_set_default_size`,改为:

```cpp
  gtk_window_set_default_size(GTK_WINDOW(window), 960, 680);
```

（若已有该行,改数值;若无,在 `gtk_widget_show(GTK_WIDGET(window));` 之前加。）

- [ ] **Step 5: Linux 冒烟构建**

Run: `flutter build linux --debug`
Expected: 构建成功,产出 `build/linux/x64/release/bundle/`（debug 在 `build/linux/x64/debug/bundle/`）。若失败看错误(常见:缺系统库 `clang`/`cmake`/`ninja`/`libgtk-3-dev`,用 `sudo pacman -S cmake ninja clang gtk3` 装之)。

- [ ] **Step 6: Linux 运行冒烟**

Run: `build/linux/x64/debug/bundle/astrbot_app`（或 `flutter run -d linux`）
Expected: 窗口 960×680 打开,不崩。若首访 DB 崩则 FFI 未生效(T1 回看)。

- [ ] **Step 7: Commit**

```bash
git add windows/ linux/
git commit -m "feat(desktop): 启用 Windows/Linux runner + 默认窗口 960x680"
```

---

## Task 10: 宽窗居中列布局

**Files:**
- Modify: `lib/screens/chat_screen.dart`

- [ ] **Step 1: 找根布局**

Run: `grep -n "ListView\|Column\|build(BuildContext\|return Scaffold\|_inputBar\|SafeArea" lib/screens/chat_screen.dart | head -20`
定位 `_ChatScreenState.build` 的 Scaffold body 结构:消息 ListView + 底部输入栏。

- [ ] **Step 2: 包居中约束列**

把 Scaffold body 的整体内容(消息列表 + 输入栏的 Column)包进:

```dart
Center(
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 760),
    child: <原有 body 内容>,
  ),
)
```

若原 body 是 `Column(children:[ Expanded(ListView), inputBar ])`,改为:

```dart
body: Center(
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 760),
    child: Column(children: [ Expanded(child: <ListView>), <inputBar> ]),
  ),
),
```

- [ ] **Step 3: 验证 analyze**

Run: `flutter analyze lib/screens/chat_screen.dart`
Expected: 无 error。

- [ ] **Step 4: Linux 运行看布局**

Run: `flutter run -d linux`
Expected: 宽窗下消息列居中,两侧留白;窄窗(手动缩小)填满。气泡 maxWidth 仍受 `_w - 48` 约束,在 760 列内正常。

- [ ] **Step 5: Commit**

```bash
git add lib/screens/chat_screen.dart
git commit -m "feat(desktop): 宽窗居中列(maxWidth 760)"
```

---

## Task 11: Linux 端到端冒烟测试

**Files:** 无（手动验证）

- [ ] **Step 1: 启动 release 构建**

Run: `flutter build linux --release`
Expected: 成功产出 `build/linux/x64/release/bundle/`。

- [ ] **Step 2: 配置账户并运行**

注入账户(用设备无关方式):直接在 app 内 SetupScreen 输入第一个账户(serverUrl=`https://astrbot.zztweb.top`, token=`f6428ad4e65b4135`)。Linux 桌面可键入中文/英文,无 ADB 限制。
Expected: 进入 ChatScreen,历史拉取(SSE 连接)。

- [ ] **Step 3: 发消息 + 收流式 markdown**

发「请用 markdown 回复:二级标题、列表、代码块、链接 https://flutter.dev」。
Expected: bot 流式回复期间符号不闪烁(markdown 实时渲染);最终气泡表格/代码块正常。

- [ ] **Step 4: 点链接开浏览器**

点消息中的 `https://flutter.dev`。
Expected: 系统默认浏览器打开该 URL。

- [ ] **Step 5: 历史合并验证**

退出(关窗)再开,历史保留。
Expected: 重开后消息仍在(DB 持久化)。

- [ ] **Step 6: 录音/播放**

按住录音(若 Linux 有麦克风)发一条语音;收到 bot 音频回复点播放。
Expected: 录音上传成功;音频气泡显示且可播放。若无麦克风或 audioplayers 缺系统库,记录降级情况(不 fatal 即可)。

- [ ] **Step 7: 记录结果**

在 plan 文件或 commit message 记录冒烟结果。无需 commit 代码(本任务无代码改动)。

---

## Task 12: Windows CI workflow

**Files:**
- Create: `.github/workflows/build-windows.yml`

- [ ] **Step 1: 写 workflow**

`.github/workflows/build-windows.yml`:

```yaml
name: build-windows

on:
  push:
    tags: ['v*']
  workflow_dispatch:

jobs:
  windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          flutter-version: '3.38.6'
      - run: flutter config --enable-windows-desktop
      - run: flutter pub get
      - run: flutter build windows --release
      - name: Zip Release
        run: Compress-Archive -Path build/windows/x64/runner/Release/* -DestinationPath astrbot-windows.zip
      - name: Upload to GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: astrbot-windows.zip
          token: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 2: Commit workflow**

```bash
git add .github/workflows/build-windows.yml
git commit -m "ci: Windows 桌面构建(tag 触发,产物上传 release)"
```

- [ ] **Step 3: 推送验证（可选,待 v1.2.8 tag 时真实触发）**

本任务不单独触发(无 tag)。Task 13 打 v1.2.8 tag 时自动触发,届时看 Actions 结果。

---

## Task 13: 发版 v1.2.8

**Files:**
- Modify: `android/app/build.gradle.kts`

- [ ] **Step 1: bump 版本**

`android/app/build.gradle.kts`:
- `versionCode = 19` → `versionCode = 20`
- `versionName = "1.2.7"` → `versionName = "1.2.8"`

- [ ] **Step 2: 构建 Android release**

Run: `flutter build apk --release`
Expected: `build/app/outputs/flutter-apk/app-release.apk`。

- [ ] **Step 3: 构建 Linux release 并打包**

Run:
```bash
flutter build linux --release
cd build/linux/x64/release && tar czf /tmp/astrbot-linux-v1.2.8.tar.gz bundle && cd -
```
Expected: `/tmp/astrbot-linux-v1.2.8.tar.gz`。

- [ ] **Step 4: Commit + tag**

```bash
git add android/app/build.gradle.kts
git commit -m "chore: 1.2.8 桌面支持(Windows+Linux)"
git tag v1.2.8
```

- [ ] **Step 5: 推送 main + tag**

Run:
```bash
TOKEN=$(gh auth token)
git push "https://x-access-token:${TOKEN}@github.com/zzttzzmyswy/astrbot-app.git" main
git push "https://x-access-token:${TOKEN}@github.com/zzttzzmyswy/astrbot-app.git" v1.2.8
```
Expected: 推送成功;v1.2.8 tag 触发 build-windows workflow。

- [ ] **Step 6: 等 Windows CI 构建完**

Run: `gh run watch -R zzttzzmyswy/astrbot-app`（或 `gh run list` 找 build-windows run）
Expected: workflow 成功,`astrbot-windows.zip` 上传到 v1.2.8 release(draft 或 published)。

- [ ] **Step 7: 创建/补全 release**

若 workflow 用 softprops 上传到未创建的 release 会自动建。补 release notes:

```bash
gh release edit v1.2.8 -R zzttzzmyswy/astrbot-app \
  --title "v1.2.8 - 桌面支持(Windows + Linux)" \
  --notes "..."
gh release upload v1.2.8 /tmp/astrbot-linux-v1.2.8.tar.gz build/app/outputs/flutter-apk/app-release.apk --clobber
```

（Windows zip 已由 CI 上传,此处补 APK + Linux tar.gz。）

- [ ] **Step 8: 验证 release 资产齐全**

Run: `gh release view v1.2.8 -R zzttzzmyswy/astrbot-app`
Expected: 资产含 APK + Linux tar.gz + Windows zip。

---

## 完成标准

- [ ] `flutter analyze` 全 lib 无 error
- [ ] `flutter build apk --release` 成功(Android 不回归)
- [ ] `flutter build linux --release` 成功 + 桌面端冒烟通过(Task 11 全绿)
- [ ] Windows CI 在 v1.2.8 tag 触发并产出 zip
- [ ] v1.2.8 release 资产齐全(APK + Linux + Windows)
- [ ] 桌面单测(keep_alive_desktop / permission_desktop / update_desktop)全 PASS
