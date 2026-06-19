# 上传进度条卡 0% 修复 设计

**日期:** 2026-06-18
**范围:** AstrBot Android 客户端(`/home/zzt/workspace/astrbot-app`)上传媒体(图片/语音/文件)时的进度展示。

## 问题

发送图片/语音/文件时,气泡上的上传进度条**始终显示 0%**,直到上传完成后遮罩才"直接消失",全程没有动态变化。现象对所有大小的文件都成立(含几十 MB 的视频),且上传本身是成功的(`attachment_id` 正常返回,消息能发出)。

## 现状链路

`file_service.dart` 用 Dio 上传:

```dart
final response = await dio.post(
  '/api/v1/file', data: form,
  options: Options(headers: {'X-API-Key': apiKey}),
  onSendProgress: onProgress,
);
```

`onProgress` → `chat_screen.dart` 闭包 → `updateUploadProgress(key, s/t)`:

```dart
onProgress: (s, t) {
  ref.read(chatProvider.notifier).updateUploadProgress(key, t > 0 ? s / t : 0);
},
```

`updateUploadProgress` 找到 `createdAt == key` 的消息,`copyWith(uploadProgress: progress)` 触发重建;`_UploadBadge(progress)` 据此渲染百分比与圆形进度。

逻辑上链路是通的。问题落在 `onSendProgress` 是否真的触发、以及 `total` 是否有效。

## 根因假设(待诊断区分)

- **A. `onSendProgress` 不触发** —— 上传成功但回调从未调用。
- **B. 触发但 `total ≤ 0`** —— 分块传输/content-length 未知,`t > 0 ? s/t : 0` 恒为 0。

## 附带 bug:`copyWith` 无法清空 `uploadProgress`

```dart
uploadProgress: uploadProgress ?? this.uploadProgress,
```

传 `null`(`finalizeMediaSend`/`failMediaUpload` 的清空意图)时,`null ?? this.uploadProgress` 回退到旧值,**进度永远清不空**。这是一个与卡 0% 无关但确定存在的 bug,修复时一并处理。

## 诊断步骤

`file_service.dart` 的 `uploadFile` 临时加日志:

```dart
onSendProgress: (s, t) {
  debugPrint('[upload] sent=$s total=$t');
  onProgress?.call(s, t);
},
```

构建安装,发一个大文件(视频,几十 MB),抓 logcat:

| 观察 | 结论 | 走修法 |
|---|---|---|
| 多行 `sent=X total=Y`,`Y>0` 递增 | 链路正常,问题在 UI 更新 | 另查 `updateUploadProgress`/列表重建 |
| `total=-1` 或 `total=0` | **情况 B** | B 修法 |
| 一行都没有(上传成功无回调) | **情况 A** | A 修法 |

诊断确认后移除该日志。

## 修复方案

### 通用修复:`copyWith` 清空进度(哨兵模式)

用 `Object?` 作哨兵,显式区分"未传"(用旧值)与"传 null"(清空):

```dart
const _unset = Object();

LocalMessage copyWith({
  ...,
  Object? uploadProgress = _unset,
}) => LocalMessage(
  ...,
  uploadProgress: identical(uploadProgress, _unset)
      ? this.uploadProgress
      : uploadProgress as double?,
);
```

### 情况 B 修法:total 未知时用文件大小兜底

```dart
onSendProgress: (s, t) {
  final realTotal = t > 0 ? t : file.lengthSync();
  onProgress?.call(s, realTotal);
},
```

`updateUploadProgress` 仍按 0..1 计算,total 未知也能正确爬升。

### 情况 A 修法:自驱动计数流

Dio 的 `onSendProgress` 失效时,把文件读成计数 `Stream<List<int>>`,每个 chunk 累加已发送字节并回调 `onProgress`,让进度由我们的流驱动:

```dart
int sent = 0;
final countedStream = file.openRead().map((chunk) {
  sent += chunk.length;
  onProgress?.call(sent, file.lengthSync());
  return chunk;
});
final mf = MultipartFile(
  countedStream, file.lengthSync(),
  filename: filename, contentType: MediaType.parse(contentType),
);
```

## 实施顺序

1. 加诊断日志 → 构建安装 → 发大文件 → 抓 logcat 定论。
2. 实现 `copyWith` 哨兵修复(必做)。
3. 按诊断结论实现 B 或 A 修法(择一)。
4. 移除诊断日志。
5. `flutter analyze` 通过 → arm64 release 构建 → adb 推送 → 验证进度条 0→100% 平滑爬升。
