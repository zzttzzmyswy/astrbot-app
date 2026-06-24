# BotAPI 迁移设计：从 webchat 到 botapi，多会话变多账户

> 日期：2026-06-24
> 状态：已审批（无人值守任务，由 Claude 全权审批并完成）
> 范围：AstrBot Android 客户端（/home/zzt/workspace/astrbot-app）整体迁移到 `astrbot_plugin_botapi` 提供的移动端 API，抛弃 webchat 方案。

## 1. 背景与目标

当前 App 基于 AstrBot 内置 **webchat** 接口对接：

- 凭据：单一 `serverUrl` + `apiKey`（仪表盘 X-API-Key）+ `nickname` + `configId`。
- 传输：SSE（`POST /api/v1/chat` 流式响应）或 WS（`/api/v1/chat/ws`），二者在设置页二选一。
- 多会话：单一账户下，本地维护一组服务端分配的 `session_id`，发消息时带 `session_id` 切换对话。标题取自 `GET /api/v1/chat/sessions` 的 `display_name`。
- 痛点：WS 切后台被 OS 杀会丢会话上下文、卡死 loop；SSE 仅前台收消息；弱网丢消息。

`astrbot_plugin_botapi`（插件，源码 /home/zzt/workspace/astrbot_plugin_botapi）提供了一个**专为弱网/后台断连设计的移动端 API**：

- 凭据：单一 `token`（Bearer）。token 即会话身份，**与连接解耦**——断连重连同 token 即续上。
- 传输：纯 SSE（`GET /stream`）收回复，REST（`POST /message`）发消息。发完即成功，不依赖长连接。
- 断连补消息：`GET /history?since=<int id>` + `GET /stream?since=<int id>` 自动补漏。
- 多账户：一个 botapi 实例的 `tokens` 列表里每个 token = 一个独立账户（隔离会话/历史/SSE）。

### 目标

1. **迁移到 botapi**：客户端改用 botapi 的 `/auth` `/message` `/upload` `/stream` `/history`，删除 webchat 的 SSE-chat 与 WS 客户端。
2. **多会话 → 多账户**：左侧抽屉从「会话选择栏」变为「账户选择栏」。每个账户 = 一个 botapi token（对接一个 bot/对话）。切换账户 = 切换当前连接的 botapi。
3. **精简设置**：删除 `昵称`、`API Key`、`Config ID`、`连接模式（SSE/WS）` 及其描述。账户凭据（serverUrl + token）在账户管理中维护，不再放全局设置。
4. 保留既有 UI 风格、媒体（图片/语音/文件）收发、流式渲染、自动播放语音、前台保活、OEM 后台白名单引导、主题、更新检查。

### 非目标

- 不做服务端改动（botapi 插件已提供全部所需接口）。
- 不引入 `flutter_secure_storage`（token 与原 `api_key` 一样存 SharedPreferences 明文，UI 掩码；安全存储列为后续工作）。
- 不实现 botapi 管理页功能（新增/删除 token 仍由服务端仪表盘完成；客户端只消费已有 token）。
- 不做非活跃账户的后台并行连接（同一时刻只连活跃账户的一条 SSE）。

## 2. 关键决策（无人值守，已自决）

| # | 决策 | 理由 |
|:--|:--|:--|
| D1 | **一账户一连接**：仅活跃账户维持 SSE，切换账户即断旧连新 | botapi 一 token 一会话；同时连多账户无业务必要，且省电/省连接 |
| D2 | **serverUrl 与 token 均为账户级**（每账户独立 serverUrl+token） | 「每个会话对接一个 botapi」可能跨主机；新建账户默认填上一次用过的 serverUrl 以省输入 |
| D3 | **干净迁移**：升级到 botapi 版时清空旧 webchat 消息/会话注册表，重置 `is_configured=false`，引导重新添加账户 | webchat 与 botapi 凭据/消息身份不兼容（api_key ≠ token，session_id 语义不同），保留旧数据只会造成混乱 |
| D4 | **纯 SSE，删除 WS**：botapi 本就是纯 SSE 模型 | 设置页的 SSE/WS 二选一随之移除 |
| D5 | **历史补全策略**：每次 connect 先 `GET /history?since=0` 合并入库（按 `server_id` 去重），再 `GET /stream?since=<max server_id>` 接实时流 | 始终以最新 history 为游标基准，不依赖跨断连的陈旧游标；媒体不补（服务端不持久化，符合设计） |
| D6 | **DB v6**：messages 表新增 `server_id INTEGER`（可空、索引），用于去重 botapi 历史行；`session_id` 列语义改为 `account_id`（本地账户 uuid），不改列名避免迁移 | 用 server_id 干净区分「服务端持久化行」与「实时落库行」 |
| D7 | **thinking 可见**：botapi 暴露 reasoning，渲染为流式期间可折叠的思考气泡（默认折叠），不并入答案 | 比 webchat 更丰富，且 botapi 已提供 |
| D8 | **token 掩码**：复用 `key_mask.dart`，账户列表/编辑器中 token 默认掩码、眼睛切换明文 | 与原 API Key 处理一致 |
| D9 | **/auth 用于校验**：connect 时先 `POST /auth`，401 即置「token 无效」错误态，否则继续 | 给用户即时凭据反馈 |

## 3. 架构

```
┌───────────────────────────── App ─────────────────────────────┐
│  AccountStore (prefs)  ── 账户列表 {id,label,serverUrl,token}   │
│  ChatNotifier                                                       │
│    ├─ active account → BotApiClient(serverUrl, token)             │
│    │     ├─ SSE /stream?since=<cursor>  → BotApiEvent 流           │
│    │     └─ 指数退避重连 + 回前台 history 合并补漏                  │
│    ├─ BotApiHttp (无状态 REST): /auth /message /upload /history   │
│    └─ CacheService (sqflite v6): 按 account_id 分区 + server_id 去重│
│  UI: ChatScreen + AccountDrawer + AccountEditor + Settings(精简)   │
└──────────────────────────────────────────────────────────────────┘
                        │  Bearer token + REST + SSE
                        ▼
              AstrBot + astrbot_plugin_botapi
```

会话身份由 token 决定（服务端 `{platform_id}:FriendMessage:{token}`），客户端不再生成/选择 session_id。账户切换流程：dispose 旧 client → 新建 BotApiClient → fetchHistory(merge) → openStream(since=cursor)。

## 4. 组件设计

### 4.1 `lib/models/account.dart`（新）

```dart
class Account {
  final String id;          // 本地 uuid
  final String? label;      // 用户自定义名
  final String serverUrl;   // 账户级 base URL（如 https://host/api/v1/botapi 或 https://host）
  final String token;       // botapi Bearer token
  final int createdAt;
  final int lastUsedAt;
  String get displayName =>
      (label != null && label!.isNotEmpty) ? label! : 'Bot ${id.substring(0, 4)}';
  // toJson/fromJson/copyWith（label 用 _unset 哨兵，区分未传与显式清空）
}
```

### 4.2 `lib/services/account_store.dart`（新，替代 `session_store.dart`）

纯逻辑 + `AccountStorage` 抽象（生产用 `PrefsAccountStorage` 包装 SharedPreferences，测试用内存实现）。

- 常量：`kMaxAccounts = 25`；持久化键 `accounts_v1` + `accounts_current_v1`。
- 方法：`load()` / `add(serverUrl, token, {label})`（生成 uuid，返回新账户）/ `select(id)` / `rename(id, label)` / `updateCredentials(id, {serverUrl, token})` / `delete(id, deleteMessages)` / `touchCurrent(nowMs)` / 排序按 lastUsedAt 降序 / 删当前切到另一个。
- 与 `SessionStore` 结构对称，便于照搬单测范式。

### 4.3 `lib/models/botapi_event.dart`（新，替代 `chat_event.dart` 的事件部分）

`ConnState` 枚举迁移到此处（或独立 `conn_state.dart`），供 client/provider 共用。

```dart
class BotApiEvent {
  final String event;        // message | thinking | error | ping
  final String? messageId;   // botapi_xxx（实时）或 int 字符串（catchup）
  final String? type;        // message 子类型：text|image|audio|file
  final String? subtype;     // tool_status
  final String? content;     // text:字符串；image/audio:URL；file:JSON {name,url}
  final bool? streaming;
  final bool? isFinal;
  final bool? segmentEnd;
  final int? timestamp;
  final String? code;        // error
  final String? message;     // error
  final Map<String, dynamic>? raw;
  // fromSse(eventType, dataJson)
}
```

### 4.4 `lib/services/botapi_client.dart`（新，替代 `astrbot_sse_client.dart`）

负责 SSE 长连接 + 重连 + 状态流 + 事件流。

- 构造：`BotApiClient({serverUrl, token})`。
- `connect({int? sinceCursor})`：
  1. `_setState(connecting)`；
  2. 解析 base URL → `GET /stream?since=<sinceCursor>`（Bearer，`Accept: text/event-stream`），用 `http.Client` + `StreamedResponse`；
  3. 逐行解析 SSE：`event:` 行记类型，`data:` 行累积，空行触发 `BotApiEvent.fromSse(type, json)` 投递到事件流；`ping` 忽略；
  4. 连接建立 → `connected`；读流结束/出错 → `disconnected` + 退避重连。
- `Stream<BotApiEvent> events` / `Stream<ConnState> state`。
- 重连：复用 `ReconnectAttempt`（1s→…→30s）；重连时由 provider 重新 fetchHistory 后以新 cursor 调 `connect(sinceCursor:)`。
- `dispose()`：取消定时器、关闭流控制器。
- **注意**：botapi 的发送不在本类（与旧 SSE client 不同），发送走 `BotApiHttp.sendMessage`，本类只管收。

### 4.5 `lib/services/botapi_http.dart`（新，替代 `file_service.dart` 的上传 + 新增 message/history/auth）

无状态 REST，给定 `(serverUrl, token)`。

- `Future<bool> auth()`：`POST /auth` `{token}` → 200 true / 401 false。
- `Future<String?> sendMessage({String? text, List<String>? fileIds})`：`POST /message` → `{message_id}`。
- `Future<UploadResult?> uploadFile(File, mime, {onProgress})`：`POST /upload`（multipart）→ `{file_id, name, mime_type, size}`。用 dio（带 onSendProgress）。
- `Future<List<HistoryRow>> fetchHistory({int? since, int? before, int limit=200})`：`GET /history` → 解析 `messages[]`（每条 `{message_id:int str, role, type, content, timestamp}`）+ `has_more`。
- `Future<File?> downloadByUrl(String url)`：直接 GET 媒体 URL（单次有效，收到即下载到 attachments 目录，文件名用 url 派生）。注意此 URL 免认证但单次有效。
- base URL 规整：若 `serverUrl` 以 `/api/v1/botapi` 结尾则直接拼 `/auth` 等；否则视为 host，补 `/api/v1/botapi`。提供 `_botapiBase(serverUrl)` 纯函数（可单测）。

### 4.6 `lib/services/cache_service.dart`（改，DB v6）

- `onUpgrade`：`oldV < 6` → `ALTER TABLE messages ADD COLUMN server_id INTEGER` + `CREATE INDEX idx_messages_session ON messages(session_id)`（已存在则 IF NOT EXISTS）+ 新建 `idx_messages_server ON messages(server_id)`。
- `session_id` 列语义改为 `account_id`（不改列名；所有方法形参 `sessionId` 改名 `accountId`，行为不变）。
- 新增 `Future<void> mergeHistory(List<HistoryRow> rows, {required String accountId})`：事务内逐行——若已存在同 `server_id` 则跳过；否则若存在同 `(role,content, timestamp±300000ms, account)` 的实时行（server_id 为空）则把 `server_id` 贴上去；否则插入（带 server_id）。保证历史行与实时落库行不重复。
- 既有 `insertMessage/upsert/upsertBotText/getMessages/clearSession` 保留，形参 `sessionId`→`accountId`。
- `clearAll` 保留（迁移与清缓存用）。

### 4.7 `lib/models/message.dart`（改）

- 新增 `final int? serverId;` 字段；`toMap`/`fromMap` 增列；`copyWith` 增 `serverId`。
- 媒体消息：`localPath` = 已下载文件（收到即下载）或原始文件（发出）；`content` = 展示标签（文件名/空）。`attachmentId` 列保留但不再使用（botapi 无此概念），新写入恒为 null。

### 4.8 `lib/providers/chat_provider.dart`（重写核心）

ChatState 调整：

- `sessions` → `accounts`；`currentSessionId` → `currentAccountId`；`currentSessionName` → `currentAccountName`。
- 新增 `String? streamingThinking`（思考缓冲，流式期间显示，final/新一轮清空）。
- 移除 `toolCalls/toolResults`？botapi 工具活动以 `message+subtype:tool_status` 文本到达，改为渲染为「系统提示气泡」列表项（复用 `_Inline` 风格，但不持久化、本轮清空）。保留一个 `List<String> toolStatuses` 本轮 transient。
- 移除 WS 相关字段（`_usingWs`、`_pendingQueue` 的 WS 死 socket 分支、`_probeResumeLiveness` 的 WS 僵尸判断——SSE 重连走 history 合并）。

ChatNotifier 关键方法：

- `connect()`：
  1. `_ensureAccountsLoaded()`；取 `currentAccount`；若为空（无账户）→ 置错误态「未添加账户」并 return。
  2. 加载该账户本地历史 → `_syncAccountState(messages:)`。
  3. `_client?.dispose()`；新建 `BotApiClient(serverUrl, token)`；订阅 `state`/`events`。
  4. `BotApiHttp.auth()` 校验 token：401 → 错误态「token 无效」，不连 stream；200 → 继续。
  5. `BotApiHttp.fetchHistory(since:0)` → `cache.mergeHistory(rows, accountId)` → 重新加载本地历史（合并后）→ 取 `maxServerId` 作为 cursor。
  6. `_client.connect(sinceCursor: maxServerId)`。
  7. 恢复 connectivity 监听（网络恢复时 connect）。
- `sendText(text)`：本地插 pending 消息 → `BotApiHttp.sendMessage(text:)` → 成功标 sent，失败标 error（可重发）。不再有 WS 死 socket 入队逻辑；未连接时入 `_pendingQueue`，connected 后 drain。
- 媒体发送：`createPendingMedia` → `BotApiHttp.uploadFile` → `sendMessage(fileIds:[fileId])` → finalize。`FileService` 替换为 `BotApiHttp`。
- `_handleEvent(BotApiEvent)`：
  - `message` + `subtype:tool_status` → 追加 `toolStatuses` 系统气泡（不并入答案）。
  - `message` + `type:text` + `streaming:true` → 追加 `streamingText`。
  - `message` + `type:text` + `isFinal:true` → 用 content 自纠正 `streamingText`，落库 bot 文本（`upsertBotText`，server_id 为空），清空 streamingText/toolStatuses/streamingThinking。
  - `message` + `segmentEnd` → no-op（边界）。
  - `message` + `type:image|audio|file` → 下载 URL（`BotApiHttp.downloadByUrl`）→ 建媒体气泡（localPath=下载路径），落库。
  - `thinking` → 追加 `streamingThinking`（可折叠显示）。
  - `error` → 错误气泡/错误态；`SESSION_KICKED` 特殊提示「管理员已断开此会话」。
  - `ping` → 忽略。
- `switchAccount(id)` / `addAccount(...)` / `renameAccount(...)` / `deleteAccount(...)` / `editAccountCredentials(...)`：改 store 后 `connect()`。
- 回前台 `didChangeAppLifecycleState(resumed)`：若 SSE 断 → `connect()`（会重跑 history 合并补漏）。移除 WS 僵尸探测。
- 移除 `_fetchServerSessionTitles` / `_scheduleTitleRefreshIfNeeded` / `_resolveConfigId`（botapi 无标题 API、无 configId）。

### 4.9 `lib/screens/setup_screen.dart`（改为「添加首个账户」）

表单字段：`名称（可选）`、`服务器地址`、`Token`（obscure，可切换显隐）。保存 → `accountStore.add(...)` + `select` + `set is_configured=true` → 进入 ChatScreen。可加「测试连接」按钮调 `BotApiHttp.auth()` 即时校验。

### 4.10 `lib/screens/settings_screen.dart`（精简）

移除：`昵称`、`API Key`、`Config ID`、`连接模式` 及 SSE/WS 描述 tile。
保留：主题模式、OEM 后台运行引导、清理缓存、关于/检查更新。
新增：`账户管理` tile（打开账户抽屉或账户列表页——实现上直接 `Scaffold.of(context).openDrawer()`，与 AppBar 菜单按钮一致）。

### 4.11 `lib/widgets/account_drawer.dart`（新，替代 `session_drawer.dart`）

结构与 `session_drawer` 对称：列表项 = 账户（头像=label 首字、名=displayName、副标题=serverUrl 主机名 · 相对时间）；当前账户高亮；PopupMenu（重命名 / 编辑凭据 / 删除）。新建按钮 → `AccountEditor`（add 模式）。无「占位会话」概念（账户必须先添加才存在）。打开抽屉时 `touchCurrent` 刷新排序。

### 4.12 `lib/screens/account_editor_screen.dart`（新，或对话框）

add/edit 共用表单：名称、服务器地址、Token（掩码+显隐）。edit 模式预填、Token 默认掩码。保存调 `add` / `updateCredentials`。

### 4.13 `lib/screens/chat_screen.dart`（改）

- `drawer: AccountDrawer()`；AppBar `_Bar(accountName:)`。
- 媒体发送/下载改用 `BotApiHttp`（经 provider 暴露的方法，不在 UI 直接 new FileService）。
- 媒体气泡：`_ImageBubble`/`_VoiceBubble`/`_FileBubble` 下载路径由 provider 在收到事件时即下载并写入 `localPath`，UI 只读 `localPath`（不再用 attachmentId 主动下载）。发送中的媒体仍用 localPath（原始文件）。
- 流式区新增思考气泡渲染（`streamingThinking` 非空时在答案上方显示可折叠块）。
- `needsRebuild` 中 `currentSessionName` → `currentAccountName`。

### 4.14 `lib/services/config_service.dart`（改）

- 移除 `nickname/apiKey/configId/sessionId/connectionMode` 及其 setter、`saveSetup`、`_kConnectionMode` 等。
- 保留 `themeMode/autoPlayVoice/prefs`、`init`、`_migrate`。
- 迁移：`prefs_version` 2→3；`v<3` 时清空 `chat_sessions_v1`、`chat_sessions_current_v1`、`accounts_*`（防残留）、messages 表（`CacheService.clearAll`），置 `is_configured=false`。保留 theme/autoPlay/OEM prefs。
- `isConfigured` 改为由「账户列表非空」决定？为简单与稳定，仍用 `is_configured` 布尔：添加首个账户时置 true；迁移时置 false。

### 4.15 `lib/main.dart`（改）

`configInitializedProvider` 返回 `isConfigured`；home 仍 `isConfigured ? ChatScreen : SetupScreen`。启动清理过期附件缓存改用「活跃账户」或省略（botapi 媒体单次有效，本地缓存即下载文件，7 天清理仍合理，用第一个账户的 serverUrl 或直接按目录清理——`cleanOldCache` 本就按目录，不依赖凭据，保留）。

### 4.16 删除

`lib/services/astrbot_sse_client.dart`、`lib/services/astrbot_ws_client.dart`、`lib/models/chat_session.dart`、`lib/services/session_store.dart`、`lib/services/prefs_storage.dart`（功能并入 account_store）、`lib/widgets/session_drawer.dart`、`lib/models/chat_event.dart`（ConnState 迁移到 botapi_event 或独立文件后删除）。

## 5. 数据流

### 5.1 发文本

```
UI sendText → ChatNotifier
  ├ 本地插 pending 用户消息（account_id）
  └ BotApiHttp.sendMessage(text) POST /message
       200 → 标 sent
       失败/未连接 → 标 error（可重发）或入 pendingQueue
```

### 5.2 收回复（SSE）

```
BotApiClient /stream → BotApiEvent
  thinking(streaming)        → streamingThinking 累积
  message(text,streaming)    → streamingText 累积
  message(tool_status)       → toolStatuses 系统气泡
  message(image/audio/file)  → downloadByUrl → 媒体气泡 + 落库
  message(text,final)        → 自纠正 streamingText → 落库 bot 文本 → 清空本轮缓冲
  error                      → 错误态/气泡
```

### 5.3 断连补漏

```
断网/切后台 → SSE 断
回前台/网络恢复 → connect()
  ├ BotApiHttp.fetchHistory(since:0) → mergeHistory(按 server_id 去重)
  ├ 重载本地历史（补上漏掉的文本）
  └ BotApiClient.connect(sinceCursor=maxServerId) → 续接实时流
```

媒体离线期间错过则不补（服务端不持久化），符合 botapi 设计取舍。

### 5.4 切账户

```
drawer 选账户 → switchAccount(id)
  ├ accountStore.select(id) + touchCurrent
  ├ _client.dispose()
  └ connect()（用新账户 serverUrl+token：auth→fetchHistory→openStream）
```

## 6. 错误处理

- token 无效（/auth 401）：错误态「token 无效，请在账户管理中更新」；不连 stream。
- serverUrl 不可达：连接超时 → 退避重连；错误态显示。
- /message 失败（网络）：该消息标 error，点击重发。
- /upload 失败：媒体气泡标 error，点击重试（复用 localPath）。
- SESSION_KICKED：错误气泡「管理员已断开此会话」，并停止重连（需用户手动重连/检查）。
- history 合并异常：静默（非关键路径），下次重试。

## 7. 测试

纯逻辑单测（flutter_test，无平台依赖）：

- `test/account_store_test.dart`：增删改查、25 上限、排序、删当前切到另一个、`updateCredentials`。
- `test/botapi_event_test.dart`：`fromSse` 解析各事件类型（message text/image/file、thinking、error、ping）、streaming/final/segment_end 字段。
- `test/botapi_http_base_test.dart`：`_botapiBase(serverUrl)` 规整（带/不带尾斜杠、带/不带 `/api/v1/botapi`）。
- `test/cache_service_history_test.dart`：`mergeHistory` 去重（server_id 已存在跳过、实时行贴 server_id、全新插入），用 sqflite 测试包或内存 fake。
- `test/key_mask_test.dart`：既有，token 掩码复用，保留。
- `test/oem_whitelist_test.dart`：既有，保留。

集成验证（ADB 真机，Pixel）：

- 构建安装 → 首启 setup 添加账户（真实 botapi token）→ 收发文本 → 流式渲染 → 切后台回前台补消息 → 切账户 → 发图/语音/文件 → 自动播放语音 → 主题切换 → 更新检查。
- 无真实 token 时至少 `flutter analyze` + `flutter test` + 构建 APK 通过。

## 8. 迁移影响

- 既有用户升级后：旧 webchat 消息/会话被清空，需重新添加 botapi 账户（D3）。这是有意的干净切断。
- 依赖：无新增 package（http/dio/sqflite/shared_preferences 等已具备）。移除对 `web_socket_channel` 的使用（可保留依赖不删，避免 pubspec 变动风险；仅删 WS client 代码）。
- 版本：`build.gradle.kts` versionName 1.1.9 → 1.2.0（major 协议迁移），versionCode 11 → 12。

## 9. 风险

| 风险 | 缓解 |
|:--|:--|
| SSE 在 Android 后台仍可能被 OS 冻结 | 前台保活服务保留；回前台 history 合并补漏兜底（botapi 核心卖点） |
| 媒体单次 URL 错过即丢 | 符合 botapi 设计；UI 收到即下载；离线错过的媒体不补，文本可补 |
| 多账户 token 明文存储 | 与原 api_key 一致；UI 掩码；安全存储列后续 |
| DB v6 迁移失败 | `server_id` 用 `ALTER ADD COLUMN`（SQLite 支持），索引 `IF NOT EXISTS`，幂等 |
| 旧用户对「数据被清」不满 | 这是协议迁移的必然；setup 引导重新配置；版本号升至 1.2.0 标注 breaking |
