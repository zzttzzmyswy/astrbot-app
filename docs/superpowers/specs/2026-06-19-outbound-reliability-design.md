# 连接可靠性第二轮:出站消息与生成兜底 设计规格

> 日期:2026-06-19 · 范围:AstrBot Android 客户端(`/home/zzt/workspace/astrbot-app`)
> 目标:稳定性第一轮已完成「连接保活」(SSE 自动重连、生命周期重连、前后台保活、上传/下载重试、WS 被动活跃检测)。本轮聚焦第一轮**未覆盖**的「单条消息 / 单次生成」可靠性。
> 约束:无人值守执行;改动须保持 Riverpod 2.5 + StateNotifier 架构一致;复用现有 `MessageStatus` 与媒体失败重发 UX;不破坏消息去重 / 锚定 / 共享播放器等既有设计;不做服务端不支持的能力。

---

## 1. 背景:第一轮已覆盖 vs 本轮残留缺口

第一轮(随开源 squash 进 v1.0.0,v1.1.x 加固)已实现:
- SSE 自动重连(`ReconnectAttempt` 指数退避)+ 健康探测改为 `GET /api/v1/configs`(不再发空消息污染会话)。
- WS 指数退避重连 + 被动活跃检测(长生成时把任意入站帧视为存活,不误掐)。
- 生命周期重连(`WidgetsBindingObserver` + `shouldReconnectOnResume`)。
- 前台服务保活(`flutter_foreground_task`)+ 网络恢复自动重连(`connectivity_plus`)。
- 上传 / 下载 `withRetry`(瞬态错误才重试)。
- `ConnState` 四态含 `reconnecting`。

**本轮真实残留缺口**(均有 `file:line` 依据):

| # | 缺口 | 位置 |
|---|------|------|
| G1 | 文本消息发送**零重试**:SSE 单次 POST(无 `withRetry`),WS 单次 `sink.add`;瞬态失败后消息本地标 `sent` 但服务端从未收到,只重连连接不重发消息 | `chat_provider.dart:327` `sendText` → 客户端 `sendMessage` |
| G2 | WS 死 socket 上发送的消息**静默丢失**:`sendMessage` 检测到死 socket 只调 `_forceReconnect()` 治连接,不把该消息入队重发 | `astrbot_ws_client.dart:151-155` |
| G3 | SSE 模式**无法后台接收服务端主动推送**:当前 SSE 是「每条消息一次 POST + 流式响应」,非持久 `EventSource`;没人发消息时收不到 bot 推送(WS 才行) | 架构限制,无持久订阅端点 |
| G4 | 生成中途断网 → `streamingText` 半截内容**变孤儿气泡**(留在 UI 不落盘,无 `complete`/`end`) | `chat_provider.dart:569-607` |

---

## 2. 不在本轮范围(YAGNI)

- 不重写 WS/SSE 客户端(第一轮已稳)。
- 不引入服务端不支持的能力:持久 SSE 推送订阅、生成断点续传。
- 不改 UI 视觉(本轮纯稳定性)。
- 不为 G3 造轮子:核实 AstrBot 无持久 SSE 订阅端点后,**文档化**而非自建轮询。

---

## 3. 设计

### 3.1 G1 + G2:出站消息可靠投递层(核心)

**目标**:连接活着但消息丢了 / 发到死 socket 上的消息,都不再静默丢失。

#### 3.1.1 文本消息增加 `error` 态 + 点击重发(复用媒体已有 UX)

`MessageStatus` 已有 `error` 态(媒体上传失败用),失败气泡点击重发已实现(`retryMediaSend`,`chat_screen.dart:959/1033`)。本轮:

- `sendText` 发送失败时把消息置 `MessageStatus.error` 并持久化(当前置 `sent` 后失败不可挽回)。
- 新增 `retryTextSend(int createdAt)`,与 `retryMediaSend` 对称:取出原文本内容 → 重新走发送 → 成功置 `sent`,失败保持 `error`。
- 文本气泡在 `status == error` 时渲染点击重发入口(复用 `_FileBubble`/`_ImageBubble` 的 errored 分支同款样式)。

#### 3.1.2 SSE:首字节前重试 + 失败关联到「最近 pending」消息

`_sendHttpMessage`(`astrbot_sse_client.dart:127`)两处改动:

**(a) 首字节前重试(不重试已开始的流)**:把「建立请求 + 收到首字节」阶段包一层重试:
- 仅当 `_awaitingFirstByte == true`(请求已发但首字节未到)且错误为瞬态(连接/发送超时、`SocketException`、连接重置)才重试。
- 一旦首字节到达(`_awaitingFirstByte = false`)→ 进入流式,**不再重试**(中途断开交由 G4 兜底)。
- 重试用现有 `withRetry` 思路,`maxAttempts: 3`,退避 `1000<<i` ms,与 `FileService` 一致。

> 注:http 包(http.Client)无 Dio 的 `DioExceptionType`,因此 SSE 侧写一个等价的瞬态判定函数(`isTransientHttpError`:连接/发送超时、`SocketException`、连接重置),放在 `util/retry.dart`。

**(b) 失败如何关联到具体消息(SSE 是 fire-and-forget,返回值无用)**:
- `sendMessage` 在 SSE 模式下是异步 POST,error 经事件流(`error` 事件)+ 重连回传,**不携带消息 id**,故不能用返回值关联。
- 约定:AstrBot 按会话**串行**处理消息(用户发一条、服务端流式回一条),同一时刻至多一条「在途」文本。ChatNotifier 维护 `_inflightTextCreatedAt`;`sendText` 发送时记录它;收到该消息的首个流式事件(`plain`/`session_id`)或 `complete`/`end` 即视为送达 → 置 `sent` 并清空;收到 `error` 事件且 `_inflightTextCreatedAt` 仍在途 → 把该消息置 `error`(供点击重发)。
- 该假设在「串行会话」下成立;若用户连发多条,SSE 各自独立 POST,服务端仍按序回写,「最近 pending」关联在串行回写下正确。媒体发送走 `attachment_id` 流程,不受影响。

#### 3.1.3 WS:死 socket 上发送的消息入出站队列重发

`sendMessage`(`astrbot_ws_client.dart:143`)当前死 socket 只 `_forceReconnect()`:
- 改为:`_sendRaw` 已返回 bool;`sendMessage` 把它透传回调用方(改返回类型为 `bool`,WS 下 `sink.add` 同步可知成败)。
- ChatNotifier 侧:`sendText` 调 `sendMessage` 后,若 WS 返回 false(死 socket)→ 把这条消息**保持 `pending` 并加入 `_pendingQueue`**;重连成功后由现有的 pending drain(`chat_provider.dart:288-293`)自动重发。
- 已有 pending drain 机制,只需让「死 socket 发送」也走它,而非丢弃。

#### 3.1.4 出站可靠性状态机(文本)

```
pending ──发送成功(WS sink 成功 / SSE 首字节到)──► sent
   │                                            ▲
   └──发送失败(瞬态,重试用尽 / 死 socket)──► error ──点击重发──► pending(回环)
```

### 3.2 G4:生成中途断网的半截回复兜底

**目标**:不丢失已生成的文本,且用户能看出「这是中断的」。

新增:在 `_handleEvent` 的 `error` 分支 + 连接 `disconnected`/`reconnecting` 且存在非空 `streamingText` 且本轮**未收到** `complete`/`end` 时:
- 把 `streamingText` 落盘为一条文本消息,`content` 追加后缀 `\n\n_(回复中断,请重试)_`。
- 清空 `streamingText`。
- **不尝试续传**(服务端不支持);用户可重发自己的消息触发重新生成。

实现位置:`chat_provider.dart` 的状态监听(`connectionState` 变 disconnected/reconnecting)里,或 error 事件里——需确保只在「有进行中的流且未完成」时触发,避免重复落盘(复用 `_cache.upsertBotText` 的内容去重)。

### 3.3 G3:SSE 后台推送限制 → 文档化(不造轮子)

核实:AstrBot 的 SSE 不是订阅流,客户端通过 `POST /api/v1/chat` 发消息、服务端在**该次响应**里流式回写;无独立的 `GET` 订阅端点。因此 SSE 模式在「没有进行中的请求」时,物理上无法收到服务端主动推送。

处理:
- **不**自建轮询(无对应端点,且违背 SSE 语义)。
- 在设置页「连接模式」处补一行说明:SSE 更稳定但仅在请求-响应期间收发;需要后台实时接收 bot 推送请用 WebSocket。
- 默认仍 SSE(第一轮已定:更稳),WS 作为「需要实时推送」的显式选项。这是诚实的权衡,不藏限制。

---

## 4. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/services/astrbot_sse_client.dart` | `_sendHttpMessage` 首字节前重试;新增 `isTransientHttpError` 瞬态判定(error 经事件流回传,不改 `sendMessage` 返回值) |
| `lib/services/astrbot_ws_client.dart` | `sendMessage` 返回 bool(是否成功),透传 `_sendRaw` 结果 |
| `lib/providers/chat_provider.dart` | `sendText` 失败→`error`;新增 `retryTextSend`;G4 半截回复兜底;WS 死 socket 发送回退入队 |
| `lib/util/retry.dart` 或 `astrbot_sse_client.dart` | http 包等价的瞬态错误判定 |
| `lib/screens/chat_screen.dart` | 文本气泡 `error` 态渲染点击重发(复用 errored 样式);设置页连接模式补 SSE 限制说明 |
| `test/` | `retry` 瞬态判定、出站状态机、G4 兜底的单测(workspace `.gitignore` 忽略 test,需 `git add -f`) |

---

## 5. 测试策略

- **瞬态判定单测**:连接超时 / SocketException / 连接重置判为瞬态;4xx、cancel 判为不重试。
- **SSE 首字节前重试单测**:mock http 在首字节前失败两次、第三次成功 → 消息最终发出,且不触发 G4(因首字节未到无 streamingText)。
- **SSE 失败关联单测**:发送后收到 `error` 事件 → 最近 pending 文本置 `error`;收到 `plain`/`complete` 后再收到 `error` → 不误标(已送达)。
- **WS 死 socket 回退单测**:`sendMessage` 在 channel 关闭时返回 false → provider 把消息保持 pending 入队 → 重连后 drain 重发。
- **G4 兜底单测**:有 streamingText + disconnected 且无 complete → 落盘一条带「中断」后缀的消息;有 complete → 不触发。
- **文本重发单测**:`retryTextSend` 从 error 态取内容重新发送成功 → sent。

构建验证:arm64 release 构建 + 安装到无线 ADB 设备启动存活(memory: 包名 `top.zztweb.astrbot`,arm64 构建)。

---

## 6. 验收标准

1. 文本消息在弱网(瞬态失败)下重试后最终送达,不静默丢。
2. WS 模式下往刚死的 socket 发消息,重连后自动补发,用户无需手点。
3. 生成中途断网,已生成文本落盘并标注中断,不留孤儿气泡。
4. SSE 模式后台推送限制在设置页如实说明。
5. `flutter analyze` 0 error;新单测通过。
