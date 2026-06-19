# 稳定性深度优化 + UI 打磨 设计规格

> 日期:2026-06-19 · 范围:AstrBot Android 客户端(/home/zzt/workspace/astrbot-app)· 目标:在 WS/SSE 双模式下全面提升连接与数据传输稳定性,并对视觉与动画做深度打磨。
> 约束:无人值守执行;改动须保持与现有 Riverpod 2.5 + StateNotifier 架构一致;不破坏既有的消息去重/锚定/共享播放器等关键设计。

---

## 1. 背景与动机

探索代码后发现以下**实打实的缺口**(均有 `file:line` 依据):

### 稳定性缺口
| # | 缺口 | 位置 |
|---|------|------|
| S1 | SSE 完全没有自动重连;WS 有指数退避重连,SSE 仅靠 `chat_provider` 的"网络切换"事件重连 | `astrbot_sse_client.dart`(无重连器) |
| S2 | SSE 每次 `connect()` 发一条空消息 `text:''` 做连通测试 → 真实对话往返、污染会话、每次重连都发 | `astrbot_sse_client.dart:40-57` |
| S3 | 全项目无 `WidgetsBindingObserver`;回前台时不重连静默死亡的连接 | `main.dart` / `chat_provider.dart` |
| S4 | 弱网上传/下载零韧性:单次尝试,中途抖动即整体失败,不重试不可续 | `file_service.dart` |
| S5 | SSE 流式响应仅 300s 粗超时;弱网下可能静默卡死数分钟 | `astrbot_sse_client.dart:141` |
| S6 | 退避重连期间状态显示"未连接(红)",观感像故障 | `ConnState` 仅 3 态 |
| E | 流式 chunk 触发整张 SliverList 重建(长历史+快流式 = 卡顿) | `chat_screen.dart` ref.listen |
| A | Markdown 静态缓存永不清理 → 长会话内存只增不减 | `chat_screen.dart` `_MarkdownContentState._cache` |
| C | `cleanOldCache()` 已实现 7 天清理但**从未被调用** → 磁盘缓存无限增长 | `file_service.dart:109` |
| Q | 每次录音内联 `AudioRecorder()` 且从不 dispose → 原生录音资源泄漏 | `chat_screen.dart:425` |

### UI 缺口
| # | 缺口 |
|---|------|
| U1 | 聊天背景纯白/纯黑平铺,无层次 |
| U2 | 两套强调色并存:紫 `#5B4BD6`(气泡/输入/附件)与蓝 `#007AFF`(顶栏喇叭/打字/工具调用) |
| U3 | 顶栏喇叭图标无 tint 底,浅色下对比度弱于附件面板色块图标 |
| U4 | 录音浮层 18 根波形条 ×1100ms 循环过繁 |
| U5 | 失败媒体气泡无重发入口,弱网失败后无法挽回(与 S4 互补) |

---

## 2. 架构与分解

两条协同工作流,放一份规格、一份计划,**稳定性先行**(影响数据正确性),**UI 其后**(纯视觉/渲染)。两者共享统一强调色体系(§5.2)。

### 职责边界
- `AstrBotSseClient` —— 补齐连接可靠性(重连、只读探测、空闲看门狗),与 WS 对齐。
- `AstrBotWsClient` —— 已有被动存活检测,仅对齐 `reconnecting` 状态与状态机口径。
- `ChatNotifier` —— 监听 client.state,断线即防抖重连;新增生命周期观察。
- `FileService` —— 加重试包装与磁盘清理调用。
- `ChatScreen` —— 渲染性能(流式隔离)、视觉(背景/图标/动画)、资源(录音器释放)。
- 新增小型纯逻辑单元以便单测:重连退避序列、重试策略、生命周期状态机。

---

## 3. 稳定性方案(架构层)

### 3.1 SSE 自动重连 + 统一连接状态机 [S1 / S6]
- `AstrBotSseClient` 增加指数退避重连器(1s→2s→4s…封顶 30s),镜像 `AstrBotWsClient`。
- 触发时机:health-check 失败、SSE 流 `await for` 抛错或结束(非主动 dispose)。
- `_disposed` 守卫,重连前 cancel 旧 timer。
- `ConnState` 增 `reconnecting` 语义;退避期间报 `reconnecting`,连上后 `connected`。
- `WS` 侧:被动存活检测保留;把其 `_onDisconnected` 的退避阶段也归一到 `reconnecting`,使两模式状态机口径一致。

### 3.2 ChatNotifier 断线即重连 [S1 协同]
- 当前仅在"网络切换且处于 disconnected"时重连。新增:监听 `client.state`,凡"曾 connected 后转 disconnected"即触发防抖重连(300ms 合并连发),与 3.1 的客户端自重连协同(由客户端主重连,provider 作兜底,避免双重重连——provider 仅在客户端长时间无反应的极端情况兜底)。

### 3.3 应用生命周期观察者 [S3]
- `ChatNotifier` 实现 `WidgetsBindingObserver`(或新建 `LifecycleReconnectObserver` 注入)。
- `resumed`:若 `connectionState != connected`,触发 `connect()`。
- `paused`/`hidden`:不主动断开(前台服务保活),依赖现有心跳/存活检测。
- 只挂载一次,dispose 时移除。

### 3.4 移除空消息探测,改只读连通校验 [S2]
- `AstrBotSseClient.connect()` 删除 `POST /api/v1/chat` 带 `text:''`。
- 改为 `GET /api/v1/configs`(health check 已用的只读接口)校验 200 + API key 有效,再置 `connected`。
- session_id 继续由首条真实消息的 SSE 响应带出现有逻辑,不动。

### 3.5 上传/下载弱网韧性 [S4 / U5]
- `FileService.uploadFile`:对**瞬态错误**(`connectionTimeout/sendTimeout/receiveTimeout/connectionError` 及 SocketException)重试 ≤3 次,指数退避(1s→2s→4s);4xx/`status==error` 立即失败不重试;保留 `onSendProgress`。
- `FileService.downloadAttachment`:同样 ≤3 次瞬态重试;保留现有 JSON-错误体防污染逻辑。
- 失败媒体气泡(`MessageStatus.error`)保留 `localPath`,加"点击重试"入口 → 复用 `uploadFile`+`finalizeMediaSend`。
- 断点续传需服务端支持,本期不做(无 API),仅整文件重试。

### 3.6 SSE 空闲看门狗 [S5]
- 仅在"已发送、尚未收到首字节"阶段设 ~30s 空闲阈值;超时发 error 事件让 UI 提示。
- 流式进行中沿用 300s(生成本就可能很长,不可误掐)。

### 3.7 资源与缓存治理 [A / C / Q]
- **A**:Markdown 缓存加 LRU 上限(默认 32 条),超出按插入序淘汰;key 仍为 `theme+text`。
- **C**:App 启动时调用 `cleanOldCache()`(在 `main.dart` 初始化后或 `ChatNotifier.connect()` 首次,微任务中执行,不阻塞 UI)。
- **Q**:`_startVoice` 复用单一 `AudioRecorder` 实例(成员字段),停止时取消订阅并 `dispose()` 旧实例;避免每次录音泄漏。

### 3.8 流式渲染隔离 [E]
- 当前每个流式 chunk 触发整张 SliverList 重建。重构:尾部流式气泡抽成 `Consumer` 用 `ref.watch(chatProvider.select((s) => s.streamingText))` 订阅,使其**单独**重建;历史气泡在流式期间不再随 chunk 重建。
- 保留 `RepaintBoundary` 包裹,叠加效果叠加。

---

## 4. UI 方案(视觉层)

### 4.1 聊天背景 [U1]
- 在 `CustomScrollView` 之下铺一层主题感知 DecoratedBox:浅色=极淡冷灰线性渐变;暗色=`#0F0F0F` 带极淡径向 vignette。
- **保持极克制**:不引入纹理噪点,气泡可读性优先;放最底层不影响命中测试。

### 4.2 统一强调色 [U2]
- 全 App 非语义类强调色统一为紫 `#5B4BD6`:
  - 顶栏喇叭图标、打字动画点 `_TypingDots` 由蓝改紫。
  - 工具调用 `_ToolMsg`(`#007AFF`)/`_ToolResult`(`#34C759`)属语义色,**保留**。
  - 在线绿 `#34C759`、错误红 `#FF6B6B` 保留。

### 4.3 图标对比度 [U3]
- 顶栏喇叭按钮套用与附件面板一致的 tint 色块底(`accent.withValues(alpha: isDark?0.22:0.12)`,激活态实心 accent+白图标),保证浅/暗模式区分度。
- 沿用 `*_rounded` 线性图标族保持优雅一致。

### 4.4 录音浮层减繁 [U4]
- `_VoiceOverlay` 由 18 根条简化为 5 根更粗的条,循环周期放慢至 ~1500ms,相位错开更柔和;保留振幅驱动与"上划取消"逻辑。

### 4.5 失败重发 [U5]
- 失败媒体气泡:把错误图标改为可点;点击重跑上传 → 成功 `finalizeMediaSend`,失败再次置 error。与 3.5 重试互补(重试用尽后的用户兜底)。

---

## 5. 数据流与错误处理

- 错误继续走现有 `errorMessage` + SnackBar 通道;新增重连/重试不与既有去重逻辑冲突(重连后历史重载经现有 `attachment_saved`/`complete` 内容去重)。
- `reconnecting` 状态在顶栏显"重连中…"(中性灰),区别于"未连接(红)"。
- 重连成功后补发 `_pendingQueue`(现有逻辑),离线期间消息不丢。
- 瞬态重试失败上抛与现行失败路径一致,UI 不新增状态机分支。

## 6. 测试

新增**纯逻辑单元**覆盖可单测部分(不涉及网络/平台):
- 重连退避序列计算(1→2→…→封顶 30、reset on success)。
- 重试策略分类器:哪些异常重试、哪些立即失败、次数封顶。
- 生命周期状态机:resumed→非connected 触发重连,且去抖/不重复触发。
- Markdown LRU 淘汰行为。

UI 与连接层为集成/手动验证项(连真实服务器):静默断开重连、回前台重连、弱网重传、流式长历史流畅度。

## 7. 非目标(YAGNI)

- 断点续传上传(需服务端支持,无 API)。
- 端到端消息已读回执/多设备同步。
- 全局重设计(仅打磨现有设计语言)。
- Android 15 dataSync FGS 时限问题(系统级限制,超出客户端优化范围)。

## 8. 验收标准

- SSE 静默断开后能在退避内自动恢复;回前台时若已断则自动重连。
- 弱网下上传/下载可经重试成功;彻底失败可点气泡重发。
- 流式输出在长历史(数百条)下不卡顿(流式尾单独重建)。
- 主题统一为单一紫色强调色;顶栏图标浅/暗模式均有足够对比度。
- 长会话无内存/磁盘无限增长(缓存 LRU + 7 天清理生效)。
- 录音多次后无原生资源泄漏。
