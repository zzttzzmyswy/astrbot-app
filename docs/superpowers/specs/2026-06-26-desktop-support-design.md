# 桌面支持第一步（Windows + Linux）设计

> **范围**：让 app 在 Windows / Linux 桌面能构建、运行、聊天、收发流式 markdown、点链接、合并历史、录音/播放。**不含**系统托盘保活与桌面原生侧边栏布局（后续步骤）。Android 不得回归。

## 目标

1. `flutter build linux` / `flutter build windows` 产出可运行桌面应用。
2. 核心聊天链路（botapi SSE、http、history 合并、多账户、markdown 渲染、sqflite、riverpod UI）在桌面正常工作。
3. 移动端专属能力（前台保活、运行时权限、APK 自更新、OEM 电池白名单）在桌面安全降级为 no-op / 隐藏，绝不抛 `MissingPluginError`。
4. Android 构建与行为完全不变。

## 非目标（step 1 显式排除）

- 系统托盘 / 关窗最小化到托盘的桌面保活（关窗即断连，桌面可接受）。
- 账户列表改为常驻左侧边栏（保留现有抽屉浮层，鼠标点按钮触发）。
- Windows 原生自动更新（MSIX/Inno）；Linux 包管理器分发。
- 桌面原生窗口管理（最小尺寸约束、自定义标题栏）。

## 平台决策摘要（来自澄清）

| 议题 | 决定 |
|:--|:--|
| 目标平台 | Windows + Linux 都要 |
| 桌面更新 | 检测到新版后用 `url_launcher` 打开 release 页，不在应用内下载 |
| 窗口默认尺寸 | 宽桌面型 960×680 |
| 账户列表 | 保留抽屉浮层（不改建侧边栏） |
| 分发 | 本地构建 + GitHub release 附二进制 |

---

## 架构：平台抽象层（方案 B）

把 4 个随平台变化的能力抽成 Riverpod 注入的接口，各一对移动/桌面实现，启动时按 `Platform` 选实现。调用点只面向接口，不知平台。`Platform.is*` 只出现在 `platform_providers.dart` 一处。

### 接口与实现

```
lib/services/platform/
  keep_alive_service.dart   abstract class KeepAliveService { Future<void> init(); Future<void> start(); Future<void> stop(); }
  permission_service.dart   abstract class PermissionService { Future<bool> hasMic(); Future<bool> requestMic(); }
  update_service.dart       abstract class UpdateService { Future<void> apply(UpdateInfo info); }
  oem_service.dart          abstract class OemService { OemInfo? get(); bool openBatterySettings(); }
  impl/
    keep_alive_mobile.dart     → flutter_foreground_task（搬迁自现 foreground_service.dart）
    keep_alive_desktop.dart    → 全 no-op，仅 log
    permission_mobile.dart     → record.hasPermission（仅麦克风；通知权限归 keep_alive_mobile 由 flutter_foreground_task 处理）
    permission_desktop.dart    → 永远返回 granted，不调用任何插件
    update_mobile.dart         → 下载 APK + 原生 installApk MethodChannel（搬迁自 ApkInstaller）
    update_desktop.dart        → url_launcher 打开 release URL，不下载
    oem_mobile.dart            → MethodChannel getOemInfo / openAppLaunchSettings（搬迁自 DeviceOemService）
    oem_desktop.dart           → get() 返回 null；openBatterySettings() 返回 false

lib/providers/platform_providers.dart
  final keepAliveProvider   = Provider<KeepAliveService>((ref) => Platform.isAndroid ? MobileKeepAlive() : DesktopKeepAlive());
  final permissionProvider  = Provider<PermissionService>((ref) => Platform.isAndroid ? MobilePermission() : DesktopPermission());
  final updateProvider      = Provider<UpdateService>((ref) => Platform.isAndroid ? MobileUpdate() : DesktopUpdate());
  final oemProvider         = Provider<OemService>((ref) => Platform.isAndroid ? MobileOem() : DesktopOem());
```

### 数据模型

- `UpdateInfo { String version; String releaseUrl; String? notes; int? sizeBytes; }` — 共享，版本检查（http）产出，喂给 `UpdateService.apply`。
- `OemInfo { String manufacturer; String brand; bool hasPowerGenie; }` — 已有结构，提炼为模型类。

### 旧代码归宿

- `foreground_service.dart`（裸函数 + `keepAliveStartCallback` 顶层注解）→ 内容并入 `keep_alive_mobile.dart`；`keepAliveStartCallback` 仍须顶层 `@pragma('vm:entry-point')`，保留在 mobile 实现文件顶层。
- `apk_installer.dart`（静态 channel 调用）→ 并入 `update_mobile.dart`。
- `device_oem_service.dart` → 并入 `oem_mobile.dart`。
- `AudioService.hasPermission()` → 改读 `ref.watch(permissionProvider)`；录音 `start` 前调 `requestMic()`。

---

## 各能力行为

| 能力 | Android | Windows / Linux |
|:--|:--|:--|
| 前台保活 | flutter_foreground_task 常驻通知 | no-op |
| 麦克风权限 | `record.hasPermission()` + 请求 | 永远 granted |
| 应用更新 | 检测→下载 APK→原生 `installApk` | 检测→`url_launcher` 开 release 页 |
| OEM 电池白名单 | MethodChannel | `get()` 返回 null，设置页隐藏卡片 |
| 通知权限 | Android 13+ 请求（并入保活 init） | n/a |

## 基础设施

### sqflite 桌面 FFI（必改，不改首访 DB 崩）

`main()` 最早处：
```dart
if (Platform.isWindows || Platform.isLinux) {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}
```
加依赖 `sqflite_common_ffi`。`cache_service._initDb` / `getDatabasesPath` 不动（FFI 下返回 `path_provider` 应用支持目录）。

### 窗口默认尺寸（不引 window_manager）

改生成的 runner：
- `windows/runner/main.cpp`：默认 960×680。
- `linux/my_application.cc`：`gtk_widget_set_size_request` / 默认 960×680。
不设最小尺寸约束（移动 UI 本就为小屏设计，缩到很小也不崩；要约束后续加 `window_manager`）。

### WithForegroundTask 包裹（真实坑）

`flutter_foreground_task` 的 `WithForegroundTask` widget 在桌面无实现，碰了会 `MissingPluginError`。`MyApp.build` 按平台二选一：
```dart
final app = MaterialApp(...);
return Platform.isAndroid ? WithForegroundTask(child: app) : app;
```

### 宽窗布局适配

`chat_screen.dart` 把消息列表 + 输入栏整体包进 `Center` + `ConstrainedBox(maxWidth: 760)`。屏宽 <760 填满（移动态不变）；宽窗下居中窄列两侧留白。账户抽屉浮层不动。

---

## 构建与分发

- `flutter config --enable-windows-desktop --enable-linux-desktop`
- `flutter create --platforms=windows,linux .` 生成 runner（再改默认尺寸）。
- **Linux**：本机 `flutter build linux` → `build/linux/x64/release/bundle/` 打 tar.gz。本地冒烟测。
- **Windows**：本机 Linux 无 MSVC，`flutter build windows` 跑不通。写 `.github/workflows/build-windows.yml`，`windows-latest` runner，tag 推送（`v1.2.*`）时构建，把 `build/windows/x64/runner/Release/` 打 zip 上传到对应 release。
- v1.2.8 release：附 Android APK + Linux tar.gz + Windows zip（Windows 由 CI 上传）。

## 测试与不回归

- **单测**：4 个 desktop 实现直接实例化调用，断言 no-op / granted / null 且不抛异常。mobile 实现因依赖原生 channel/插件不做单测，靠 Android 构建保证。`platform_providers` 的 `Platform.isAndroid ? ...` 选择是一行，不单独单测，靠两端构建产物验证。
- **手动冒烟（Linux）**：加账户→发消息→收流式 markdown→点链接开浏览器→历史合并→录音/播放。
- **不回归**：`flutter build apk --release` 仍通过；Android 仅改为经接口调用，行为不变；`flutter analyze` clean。
- **风险点**：`audioplayers` Linux 可能依赖系统库（libmpv 等），缺则播放降级——冒烟确认，必要时 README 说明装依赖。

## 文件清单（预估）

新增：
- `lib/services/platform/keep_alive_service.dart` + impl ×2
- `lib/services/platform/permission_service.dart` + impl ×2
- `lib/services/platform/update_service.dart` + impl ×2
- `lib/services/platform/oem_service.dart` + impl ×2
- `lib/models/update_info.dart`、`lib/models/oem_info.dart`
- `lib/providers/platform_providers.dart`
- `windows/`、`linux/` runner（`flutter create` 生成后改尺寸）
- `.github/workflows/build-windows.yml`
- 桌面单测文件

修改：
- `lib/main.dart`（FFI init + WithForegroundTask 平台二选一）
- `lib/screens/chat_screen.dart`（宽窗居中列）
- `lib/screens/settings_screen.dart`（OEM 卡片按 `OemInfo?` 显隐；更新按钮经 `updateProvider`）
- `lib/services/audio_service.dart`（权限经 `permissionProvider`）
- `lib/providers/chat_provider.dart`（保活/连接经 `keepAliveProvider`；连接性监听保持）
- `pubspec.yaml`（+ `sqflite_common_ffi`；桌面平台生效）

删除/并入：
- `lib/services/foreground_service.dart`、`apk_installer.dart`、`device_oem_service.dart` 内容并入对应 mobile impl（文件可删或留空转出）。
