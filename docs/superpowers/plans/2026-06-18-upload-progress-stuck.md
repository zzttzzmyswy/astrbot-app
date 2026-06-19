# 上传进度条卡 0% 修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让发送图片/语音/文件时,上传进度条根据真实已发送字节平滑爬升 0→100%,而不是全程卡 0% 后突然消失。

**Architecture:** 先用临时日志诊断 Dio `onSendProgress` 是否触发及 `total` 是否有效,据此二选一修复(total 未知→用文件大小兜底;回调不触发→自驱动计数流);同时修复 `LocalMessage.copyWith` 无法清空 `uploadProgress` 的 null bug。

**Tech Stack:** Flutter 3.38.6 / Dart, Dio 5.9.2(`onSendProgress`、`MultipartFile`、`file.openRead()` 计数流), Riverpod `StateNotifier`,`flutter_test` 单元测试。

**Spec:** `docs/superpowers/specs/2026-06-18-upload-progress-stuck-design.md`

---

## 前置环境

- Flutter SDK:`/home/zzt/flutter/bin/flutter`(3.38.6)。
- 构建命令(arm64 release):
  ```bash
  cd /home/zzt/workspace/astrbot-app
  /home/zzt/flutter/bin/flutter analyze
  /home/zzt/flutter/bin/flutter build apk --release --target-platform android-arm64
  ```
- adb 推送:手机已无线连接,`adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`(华为机型需在屏幕上点确认)。
- 抓 logcat(诊断用):`adb logcat -s flutter | grep upload`(保持运行,发文件时观察)。

---

## File Structure

- **`lib/models/message.dart`** — `LocalMessage` 模型。改 `copyWith` 为哨兵模式,使 `uploadProgress: null` 能真正清空。
- **`lib/services/file_service.dart`** — `FileService.uploadFile`。加诊断日志;按诊断结果实现 total 兜底或计数流。
- **`test/message_copywith_test.dart`**(新建)— `copyWith` 哨兵行为的单元测试。

---

## Task 1: 诊断 onSendProgress 是否触发

**Files:**
- Modify: `lib/services/file_service.dart:37-42`

- [ ] **Step 1: 在 uploadFile 的 dio.post 加诊断日志**

把 `lib/services/file_service.dart` 里的:

```dart
      final response = await dio.post(
        '/api/v1/file',
        data: form,
        options: Options(headers: {'X-API-Key': apiKey}),
        onSendProgress: onProgress,
      );
```

替换为:

```dart
      final response = await dio.post(
        '/api/v1/file',
        data: form,
        options: Options(headers: {'X-API-Key': apiKey}),
        onSendProgress: (s, t) {
          debugPrint('[upload] sent=$s total=$t');
          onProgress?.call(s, t);
        },
      );
```

在文件顶部 import 区(第 1-6 行附近)确认已有 `import 'package:flutter/foundation.dart';`,若没有则补上(`debugPrint` 来自该包)。

- [ ] **Step 2: 分析通过**

Run:
```bash
cd /home/zzt/workspace/astrbot-app && /home/zzt/flutter/bin/flutter analyze
```
Expected: `No issues found!`

- [ ] **Step 3: 构建 arm64 release APK**

Run:
```bash
cd /home/zzt/workspace/astrbot-app && /home/zzt/flutter/bin/flutter build apk --release --target-platform android-arm64
```
Expected: 末尾 `✓ Built build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

- [ ] **Step 4: 推送安装**

Run:
```bash
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```
Expected: `Success`(若 `INSTALL_FAILED_ABORTED`,提示用户在手机屏幕点"安装"确认后重跑)。

- [ ] **Step 5: 抓 logcat 并发大文件,记录诊断结论**

启动抓取(单独终端,保持运行):
```bash
adb logcat -c && adb logcat -s flutter | grep '\[upload\]'
```

在 APP 里**发送一个几十 MB 的视频文件**。

观察并记录(在计划本任务下方写下结论):

| 观察 | 结论 |
|---|---|
| 多行 `sent=X total=Y` 且 `Y>0` 随时间递增 | 链路正常 → 走 **Task 4(UI 排查分支)** |
| 出现 `total=-1` 或 `total=0` | 情况 B → 执行 **Task 3a** |
| 一次上传过程**完全没有任何** `[upload]` 行 | 情况 A → 执行 **Task 3b** |

- [ ] **Step 6: Commit 诊断改动(保留日志以便后续任务继续观察)**

```bash
cd /home/zzt/workspace/astrbot-app
git add lib/services/file_service.dart
git commit -m "wip: 诊断 onSendProgress 触发情况
```

---

## Task 2: 修复 LocalMessage.copyWith 无法清空 uploadProgress(TDD)

**Files:**
- Create: `test/message_copywith_test.dart`
- Modify: `lib/models/message.dart:56-66`

- [ ] **Step 1: 写失败测试 — copyWith(null) 应清空 uploadProgress**

创建 `test/message_copywith_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/models/message.dart';

void main() {
  test('copyWith(uploadProgress: null) clears the field, not falls back to old', () {
    final m = LocalMessage(
      msgType: 'image',
      isFromMe: true,
      status: MessageStatus.uploading,
      uploadProgress: 0.42,
      createdAt: 1,
    );
    // 传 null 表示"清空",而非"保持旧值"
    final cleared = m.copyWith(uploadProgress: null);
    expect(cleared.uploadProgress, isNull);

    // 不传该参数表示"保持旧值"
    final kept = m.copyWith(status: MessageStatus.sent);
    expect(kept.uploadProgress, 0.42);
  });
}
```

- [ ] **Step 2: 运行测试,确认失败**

Run:
```bash
cd /home/zzt/workspace/astrbot-app && /home/zzt/flutter/bin/flutter test test/message_copywith_test.dart
```
Expected: FAIL,`cleared.uploadProgress` 为 `0.42`(因为 `null ?? this.uploadProgress` 回退)而非 `null`。

- [ ] **Step 3: 改 copyWith 为哨兵模式**

把 `lib/models/message.dart` 里的 `copyWith`:

```dart
  LocalMessage copyWith({
    int? id, String? msgType, String? content, String? attachmentId,
    String? localPath, bool? isFromMe, MessageStatus? status, int? createdAt,
    double? uploadProgress,
  }) => LocalMessage(
    id: id ?? this.id, msgType: msgType ?? this.msgType,
    content: content ?? this.content, attachmentId: attachmentId ?? this.attachmentId,
    localPath: localPath ?? this.localPath, isFromMe: isFromMe ?? this.isFromMe,
    status: status ?? this.status, createdAt: createdAt ?? this.createdAt,
    uploadProgress: uploadProgress ?? this.uploadProgress,
  );
```

替换为:

```dart
  // 哨兵:区分"调用方未传 uploadProgress"(保持旧值)与"显式传 null"(清空)。
  // 直接用 `uploadProgress ?? this.uploadProgress` 无法表达"清空"。
  static final Object _unset = Object();

  LocalMessage copyWith({
    int? id, String? msgType, String? content, String? attachmentId,
    String? localPath, bool? isFromMe, MessageStatus? status, int? createdAt,
    Object? uploadProgress = _unset,
  }) => LocalMessage(
    id: id ?? this.id, msgType: msgType ?? this.msgType,
    content: content ?? this.content, attachmentId: attachmentId ?? this.attachmentId,
    localPath: localPath ?? this.localPath, isFromMe: isFromMe ?? this.isFromMe,
    status: status ?? this.status, createdAt: createdAt ?? this.createdAt,
    uploadProgress: identical(uploadProgress, _unset)
        ? this.uploadProgress
        : uploadProgress as double?,
  );
```

- [ ] **Step 4: 运行测试,确认通过**

Run:
```bash
cd /home/zzt/workspace/astrbot-app && /home/zzt/flutter/bin/flutter test test/message_copywith_test.dart
```
Expected: PASS(1 test)。

- [ ] **Step 5: 全量 analyze + 全量测试无回归**

Run:
```bash
cd /home/zzt/workspace/astrbot-app && /home/zzt/flutter/bin/flutter analyze
```
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
cd /home/zzt/workspace/astrbot-app
git add lib/models/message.dart test/message_copywith_test.dart
git commit -m "fix: copyWith 哨兵模式,允许清空 uploadProgress
```

---

## Task 3a: 情况 B — total 未知时用文件大小兜底

> **仅当 Task 1 诊断为情况 B(`total=-1` 或 `total=0`)时执行本任务。** 否则跳过,执行 Task 3b 或 Task 4。

**Files:**
- Modify: `lib/services/file_service.dart:37-43`(Task 1 已加诊断日志的那段)

- [ ] **Step 1: 在 onSendProgress 里用文件大小兜底 total**

把 Task 1 写入的诊断块:

```dart
        onSendProgress: (s, t) {
          debugPrint('[upload] sent=$s total=$t');
          onProgress?.call(s, t);
        },
```

替换为:

```dart
        onSendProgress: (s, t) {
          // Dio 在分块/未知 content-length 时回传 total<=0,会导致
          // 调用方 `s/t` 计算为 0 或除零。用文件真实大小兜底。
          final realTotal = t > 0 ? t : file.lengthSync();
          onProgress?.call(s, realTotal);
        },
```

- [ ] **Step 2: analyze 通过**

Run:
```bash
cd /home/zzt/workspace/astrbot-app && /home/zzt/flutter/bin/flutter analyze
```
Expected: `No issues found!`

- [ ] **Step 3: 构建 + 推送 + 验证(见 Task 5)**

执行 Task 5 的构建推送与验证步骤;若进度条仍卡 0%,说明实际是情况 A,改执行 Task 3b。

- [ ] **Step 4: Commit**

```bash
cd /home/zzt/workspace/astrbot-app
git add lib/services/file_service.dart
git commit -m "fix: 上传进度 total 未知时用文件大小兜底"
```

---

## Task 3b: 情况 A — 回调不触发,改用自驱动计数流

> **仅当 Task 1 诊断为情况 A(上传成功但全程无任何 `[upload]` 行)时执行本任务。** 否则跳过。

**Files:**
- Modify: `lib/services/file_service.dart:23-42`

- [ ] **Step 1: 用计数流替换 MultipartFile.fromFile,自驱动进度**

把 `lib/services/file_service.dart` 里的:

```dart
      final filename = file.path.split('/').last;
      final dio = Dio(BaseOptions(
        baseUrl: serverUrl,
        connectTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 120),
        receiveTimeout: const Duration(seconds: 60),
      ));
      final form = FormData.fromMap({
        'file': await MultipartFile.fromFile(
          file.path,
          filename: filename,
          contentType: MediaType.parse(contentType),
        ),
      });
      final response = await dio.post(
        '/api/v1/file',
        data: form,
        options: Options(headers: {'X-API-Key': apiKey}),
        onSendProgress: (s, t) {
          debugPrint('[upload] sent=$s total=$t');
          onProgress?.call(s, t);
        },
      );
```

替换为:

```dart
      final filename = file.path.split('/').last;
      final dio = Dio(BaseOptions(
        baseUrl: serverUrl,
        connectTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 120),
        receiveTimeout: const Duration(seconds: 60),
      ));
      // Dio 的 onSendProgress 在本链路不触发,改为在文件读取流上自计数:
      // 每个 chunk 累加已发送字节并回调 onProgress,进度由我们自己的流驱动。
      final totalLen = file.lengthSync();
      int sent = 0;
      final countedStream = file.openRead().map((chunk) {
        sent += chunk.length;
        onProgress?.call(sent, totalLen);
        return chunk;
      });
      final form = FormData.fromMap({
        'file': MultipartFile(
          countedStream,
          totalLen,
          filename: filename,
          contentType: MediaType.parse(contentType),
        ),
      });
      final response = await dio.post(
        '/api/v1/file',
        data: form,
        options: Options(headers: {'X-API-Key': apiKey}),
      );
```

- [ ] **Step 2: analyze 通过**

Run:
```bash
cd /home/zzt/workspace/astrbot-app && /home/zzt/flutter/bin/flutter analyze
```
Expected: `No issues found!`

- [ ] **Step 3: 构建 + 推送 + 验证(见 Task 5)**

执行 Task 5 的构建推送与验证步骤;进度条应平滑爬升。

- [ ] **Step 4: Commit**

```bash
cd /home/zzt/workspace/astrbot-app
git add lib/services/file_service.dart
git commit -m "fix: 上传改用自驱动计数流,绕过失效的 onSendProgress"
```

---

## Task 4: 情况"链路正常" — UI 更新排查分支

> **仅当 Task 1 诊断显示 `total>0` 递增但 UI 仍卡 0% 时执行本任务。** 否则跳过。

`onSendProgress` 正常触发、进度算出来也对,但 UI 不刷新,说明问题在 `updateUploadProgress` → 状态 → 气泡重建这条链。

- [ ] **Step 1: 确认列表无 key 导致 stateful 气泡复用旧值**

检查 `lib/screens/chat_screen.dart` 的 `_item`(约 287-309 行)是否给每条消息的 `_Bubble` 传 `key: ValueKey(m.createdAt)`,保证上传中 `widget.m` 更新时 Flutter 重建对应气泡而非复用旧 State。若无 key 则补:

```dart
_Bubble(key: ValueKey(m.createdAt), m: m, bw: _w - 48, isDark: _isDark),
```

并让 `_ImageBubble`/`_VoiceBubble`/`_FileBubble` 在 `build` 里直接读 `widget.m.uploadProgress`/`widget.m.status`(已是当前写法)。

- [ ] **Step 2: analyze + 构建 + 推送 + 验证(见 Task 5)**

- [ ] **Step 3: Commit**

```bash
cd /home/zzt/workspace/astrbot-app
git add lib/screens/chat_screen.dart
git commit -m "fix: 列表消息加 ValueKey,确保上传进度气泡实时刷新"
```

---

## Task 5: 移除诊断日志、构建、推送、最终验证

**Files:**
- Modify: `lib/services/file_service.dart`

- [ ] **Step 1: 移除诊断日志(若采用 Task 3a/4,onSendProgress 块里无 debugPrint 需删;若 3a 保留了兜底块则只删 debugPrint)**

> 若 Task 3b 已执行(已无 debugPrint),本步跳过。
> 若 Task 3a/4 路径:确保 `lib/services/file_service.dart` 中不再有 `debugPrint('[upload]...` 与 `import 'package:flutter/foundation.dart'`(若无其它引用)。

- [ ] **Step 2: analyze 通过**

Run:
```bash
cd /home/zzt/workspace/astrbot-app && /home/zzt/flutter/bin/flutter analyze
```
Expected: `No issues found!`

- [ ] **Step 3: 单元测试全绿**

Run:
```bash
cd /home/zzt/workspace/astrbot-app && /home/zzt/flutter/bin/flutter test
```
Expected: `All tests passed!`

- [ ] **Step 4: 构建 arm64 release APK**

Run:
```bash
cd /home/zzt/workspace/astrbot-app && /home/zzt/flutter/bin/flutter build apk --release --target-platform android-arm64
```
Expected: `✓ Built build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

- [ ] **Step 5: 推送安装**

Run:
```bash
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```
Expected: `Success`

- [ ] **Step 6: 手动验证 — 三类媒体进度条平滑爬升**

在 APP 内分别发送:
1. 一张图片(几百 KB)
2. 一段语音
3. 一个大文件/视频

Expected: 三类发送时气泡立即出现,`_UploadBadge` 的百分比与圆形进度从 0% **平滑爬升到 100%**,然后气泡转为已发送(遮罩消失)。不再全程卡 0%。

- [ ] **Step 7: Commit 清理**

```bash
cd /home/zzt/workspace/astrbot-app
git add lib/services/file_service.dart
git commit -m "chore: 移除上传诊断日志"
```

---

## Self-Review

- **Spec coverage:** 诊断(Task 1)、`copyWith` null bug(Task 2)、情况 B 修法(Task 3a)、情况 A 修法(Task 3b)、UI 链路分支(Task 4)、构建验证(Task 5)——spec 每节均有对应任务。
- **Placeholder:** 无 TBD/TODO;所有步骤含完整代码与命令。
- **Type一致:** `createPendingMedia` 返回 `int createdAt`、`updateUploadProgress(int, double)`、`finalizeMediaSend(int, String, String)`、`failMediaUpload(int)` 与现有 `chat_provider.dart` 一致;`LocalMessage.copyWith` 新签名用 `Object? uploadProgress = _unset`,调用处 `uploadProgress: null` 与 `uploadProgress: progress.clamp(...)` 均合法。
