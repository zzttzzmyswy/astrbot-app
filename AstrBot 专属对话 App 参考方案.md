# AstrBot 专属对话 App — 方案与技术开发规格书

> **最终方案**：OpenAPI 路径（API Key + username 隔离 + config_id 锁定配置）
> **改动**：零 AstrBot 源码修改，完全兼容上游更新
> **认证**：API Key（scope: chat + file + config）
> **隔离**：username 参数实现多用户隔离
> **配置锁定**：config_id 参数绑定专属 Bot 配置

---

## 一、为什么选 OpenAPI 路径

AstrBot 有两种 Web 聊天通道：

| 通道 | 认证方式 | 多用户 | 配置锁定 | 适合 App？ |
|------|----------|--------|----------|-----------|
| **Dashboard WebChat** (`/chat/*`) | JWT（单管理员账号） | ❌ 单用户 | ❌ 无 config_id 参数 | ❌ |
| **OpenAPI** (`/api/v1/*`) | API Key | ✅ username 参数 | ✅ config_id 参数 | ✅ |

Dashboard 只有**一个管理员账号**（`dashboard.username`），所有 App 用户共享同一个 `creator`，无法按用户隔离 session。

OpenAPI 通过 `username` 参数实现多用户——每个请求指定自己的用户标识，session 按 `creator=username` 隔离，用户 A 的 session 用户 B 看不到。同时 `config_id` 参数可以锁定到专属 Bot 配置。

`unified_msg_origin` 格式始终为 `webchat:FriendMessage:webchat!{username}!{session_id}`，与 Dashboard 完全一致，**不存在身份错配问题**——LLM 对话上下文、消息历史、重新生成、编辑等功能全部正常。

---

## 二、系统架构

```
┌───────────────────────────────────────┐
│              你的 App (Flutter)         │
│                                         │
│  ┌──────┐ ┌───────┐ ┌──────────────┐  │
│  │UI 层 │ │本地存储│ │AstrBot SDK   │  │
│  │气泡   │ │SQLite │ │SSE/HTTP/WS   │  │
│  │媒体   │ │缓存   │ │认证/会话/附件 │  │
│  └──────┘ └───────┘ └──────────────┘  │
└───────────────────────────────────────┘
         │ HTTP+SSE / WebSocket
         ▼
┌───────────────────────────────────────┐
│          AstrBot OpenAPI               │
│                                         │
│  /api/v1/chat          ← scope: chat    │
│  /api/v1/chat/ws       ← scope: chat    │
│  /api/v1/chat/sessions ← scope: chat    │
│  /api/v1/configs       ← scope: config  │
│  /api/v1/file          ← scope: file    │
│                                         │
│  认证: X-API-Key                        │
│  用户隔离: username 参数                 │
│  配置锁定: config_id 参数                │
└───────────────────────────────────────┘
         │ asyncio.Queue
         ▼
┌───────────────────────────────────────┐
│  WebChatAdapter → EventBus             │
│  → Pipeline → LLM/Agent               │
└───────────────────────────────────────┘
```

---

## 三、AstrBot 后端配置

### 3.1 创建 API Key

Dashboard → API Key 管理：

| 字段 | 值 | 说明 |
|------|------|------|
| 名称 | `my_app_key` | 自定义 |
| 权限 | `chat`, `file`, `config` | **不加 `im`**——App 只和 webchat 对话 |
| 有效期 | 长期/无期限 | 按需 |

四个权限的作用：

| 权限 | 覆盖端点 | App 是否需要 |
|------|----------|-------------|
| **chat** | `/v1/chat`、`/v1/chat/ws`、`/v1/chat/sessions` | **必须** — 发消息、列会话 |
| **file** | `/v1/file` (上传+下载) | **必须** — 图片/音频/文件收发 |
| **config** | `/v1/configs` | **建议** — 查配置列表（也可硬编码 config_id 省掉） |
| **im** | `/v1/im/message`、`/v1/im/bots` | **不需要** — 向其他平台发消息 |

**最少权限**：`chat` + `file`（config_id 硬编码时）
**推荐权限**：`chat` + `file` + `config`

### 3.2 创建专属 Bot 配置文件

Dashboard → 配置管理 → 新增配置：

- 指定 LLM provider 和 model
- 指定人格（persona）/ 系统提示词
- 指定工具集

记录配置 ID（如 `my_bot`），硬编码到 App。

### 3.3 配置文件锁定机制

App 每次请求带 `config_id`，AstrBot 会将该 session 的配置路由锁定：

```
umo = "webchat:FriendMessage:webchat!{username}!{session_id}"
→ umop_config_router.update_route(umo, config_id)
```

效果：该 session 的所有后续对话自动走指定配置的 LLM/人格/工具，无需每次请求都带 `config_id`（首次设定后自动生效）。

---

## 四、API 接口完整规格

### 4.1 发送消息（SSE 流式）— 核心接口

```
POST /api/v1/chat
Headers: X-API-Key: abk_xxxxxxxx

Body:
{
  "username": "user_a",              ← 必填，App 用户标识
  "session_id": "sid_abc123",        ← 可选，首次不传则自动生成
  "message": [{"type": "plain", "text": "你好"}],
  "config_id": "my_bot",             ← 可选，锁定配置文件
  "enable_streaming": true           ← 默认 true
}

Response: SSE stream
```

**SSE 事件类型**：

| 事件 | 含义 | 示例 |
|------|------|------|
| `session_id` | 会话绑定 | `{"type":"session_id","session_id":"sid_abc"}` |
| `plain` | 文本片段（流式追加） | `{"type":"plain","data":"你好","streaming":true}` |
| `image` | 图片 | `{"type":"image","data":"[IMAGE]uuid.jpg"}` |
| `record` | 音频 | `{"type":"record","data":"[RECORD]uuid.wav"}` |
| `video` | 视频 | `{"type":"video","data":"[VIDEO]uuid.mp4"}` |
| `file` | 文件 | `{"type":"file","data":"[FILE]uuid.pdf"}` |
| `attachment_saved` | 附件保存完成 | `{"data":{"id":"att_xxx","type":"image"}}` |
| `message_saved` | Bot 消息持久化 | `{"data":{"id":42,"created_at":"..."}}` |
| `user_message_saved` | 用户消息持久化 | `{"data":{"id":41,"llm_checkpoint_id":"..."}}` |
| `complete` | 消息完成 | `{"type":"complete","data":"最终文本"}` |
| `end` | 流结束 | `{"type":"end","data":"..."}` |
| `: heartbeat` | SSE 心跳 | `: heartbeat\n\n`（注释行） |

**SSE 解析规则**：
- `data: ` 开头 = 有效数据
- `: ` 开头 = SSE 注释（心跳），忽略
- `\n\n` = 事件分隔
- App 必须**逐行解析**，不能等整个响应完成

### 4.2 发送消息（WebSocket）

```
连接: ws://host:port/api/v1/chat/ws?api_key=abk_xxxxxxxx

上行:
{"t":"send","username":"user_a","session_id":"sid_abc","message":[...],"config_id":"my_bot"}
{"t":"ping"} → 下行 {"type":"pong"}

下行:
同 SSE 事件类型 + {"type":"end"} 结束一次对话
错误: {"type":"error","code":"UNAUTHORIZED","data":"..."}
```

### 4.3 获取会话列表

```
GET /api/v1/chat/sessions?username=user_a&page=1&page_size=20

→ {"data":{"sessions":[{"session_id":"...","creator":"user_a","display_name":"..."}],"total":1}}
```

### 4.4 上传附件

```
POST /api/v1/file  (multipart/form-data)
Headers: X-API-Key: abk_xxxxxxxx

→ {"data":{"attachment_id":"att_xxx","type":"image","filename":"uuid.jpg"}}
```

**流程**：先上传 → 拿到 `attachment_id` → 在消息段中引用

### 4.5 下载附件

```
GET /api/v1/file?attachment_id=att_xxx
→ 二进制文件流
```

### 4.6 获取配置列表

```
GET /api/v1/configs
→ {"data":{"configs":[{"id":"my_bot","name":"专属Bot配置","is_default":false}]}}
```

---

## 五、消息段格式

### 用户上行

```json
[
  {"type": "plain", "text": "你好"},
  {"type": "image", "attachment_id": "att_img_xxx"},     // 先上传再引用
  {"type": "record", "attachment_id": "att_rec_xxx"},
  {"type": "video", "attachment_id": "att_vid_xxx"},
  {"type": "file", "attachment_id": "att_file_xxx"},
  {"type": "reply", "message_id": 42, "selected_text": "被引用文本"}
]
```

**注意**：上行媒体必须用 `attachment_id`（先 `/api/v1/file` 上传获取），不能直接传 base64。

### Bot 下行

```
{"type":"plain","data":"片段文本","streaming":true}
{"type":"image","data":"[IMAGE]uuid.jpg"}       → 下载: GET /api/v1/file?attachment_id=xxx
{"type":"record","data":"[RECORD]uuid.wav"}
{"type":"file","data":"[FILE]uuid.pdf"}
{"type":"complete","data":"最终文本"}
{"type":"end","data":"..."}
```

---

## 六、"仅与某个 BOT 交互" 约束

### 配置锁定

App 每次请求带 `config_id: "my_bot"`，绑定到专属配置（指定 LLM、人格、提示词、工具集）。

### Session 锁定

App 端只维护一个 `session_id`，UI 不提供多会话切换。

### 用户隔离

不同 App 用户传不同 `username`，session 按 `creator=username` 隔离，互不可见。

---

## 七、用户身份管理

### 方案 A：共享 API Key + App 自管 username

App 自己管理用户账号 → 每个用户分配唯一 username → 传入 OpenAPI。

**优点**：简单
**缺点**：API Key 泄露后任何人可访问

### 方案 B：网关代理（更安全）

```
App 用户 → 自管认证 → 网关注入 API Key + username → AstrBot OpenAPI
```

App 用户永远不直接接触 API Key。

---

## 八、App 端 SDK（Dart/Flutter）

### 核心接口

```dart
class AstrBotClient {
  Stream<ChatEvent> sendMessage(String username, List<MessagePart> parts);
  Stream<ChatEvent> sendMessageWs(String username, List<MessagePart> parts);
  Future<AttachmentResult> uploadFile(File file, String contentType);
  Future<Uint8List> downloadAttachment(String attachmentId);
  Future<List<ChatSession>> getSessions(String username);
  Future<List<BotConfig>> getConfigs();
}
```

### SSE 实现

```dart
Stream<ChatEvent> sendMessage(String username, List<MessagePart> parts) async* {
  final request = http.Request('POST', Uri.parse('${config.baseUrl}/api/v1/chat'));
  request.headers['X-API-Key'] = config.apiKey;
  request.headers['Content-Type'] = 'application/json';
  request.body = jsonEncode({
    'username': username, 'session_id': _sessionId,
    'message': parts.map((p) => p.toJson()).toList(),
    'config_id': config.configId, 'enable_streaming': true,
  });
  
  final response = await client.send(request);
  String buffer = '';
  await for (final chunk in response.stream.transform(utf8.decoder)) {
    buffer += chunk;
    while (buffer.contains('\n\n')) {
      final block = buffer.substring(0, buffer.indexOf('\n\n'));
      buffer = buffer.substring(buffer.indexOf('\n\n') + 2);
      for (final line in block.split('\n')) {
        if (line.startsWith('data: ')) {
          final event = ChatEvent.fromJson(jsonDecode(line.substring(6)));
          if (event.type == 'session_id') _sessionId = event.sessionId;
          yield event;
          if (event.type == 'end') return;
        }
      }
    }
  }
}
```

### 多媒体发送

```dart
Future<Stream<ChatEvent>> sendImage(String username, File file) async {
  final att = await uploadFile(file, 'image/jpeg');
  return sendMessage(username, [MessagePart.plain('看这张图'), MessagePart.image(att.id)]);
}
```

### 多媒体接收

```dart
void handleEvent(ChatEvent event) {
  switch (event.type) {
    case 'plain':    appendToBubble(event.data);
    case 'image':    downloadAndShow(event.data.replaceFirst('[IMAGE]', ''));
    case 'record':   downloadAndPlay(event.data.replaceFirst('[RECORD]', ''));
    case 'file':     showDownloadButton(event.data.replaceFirst('[FILE]', ''));
    case 'complete': markBubbleDone();
    case 'end':      closeStream();
  }
}
```

---

## 九、curl 完整示例

### 纯文本

```bash
curl -X POST http://astrbot:6185/api/v1/chat \
  -H "X-API-Key: abk_xxx" -H "Content-Type: application/json" \
  -d '{"username":"user_a","message":[{"type":"plain","text":"你好"}],"config_id":"my_bot"}'
```

### 图片

```bash
# 上传
curl -X POST http://astrbot:6185/api/v1/file -H "X-API-Key: abk_xxx" -F "file=@photo.jpg"
# → {"data":{"attachment_id":"att_xxx","type":"image"}}

# 发送
curl -X POST http://astrbot:6185/api/v1/chat \
  -H "X-API-Key: abk_xxx" -H "Content-Type: application/json" \
  -d '{"username":"user_a","message":[{"type":"plain","text":"看图"},{"type":"image","attachment_id":"att_xxx"}],"config_id":"my_bot"}'
```

### 音频

```bash
# 上传
curl -X POST http://astrbot:6185/api/v1/file -H "X-API-Key: abk_xxx" -F "file=@voice.wav"
# 发送
curl -X POST http://astrbot:6185/api/v1/chat \
  -H "X-API-Key: abk_xxx" -d '{"username":"user_a","message":[{"type":"record","attachment_id":"att_rec"}],"config_id":"my_bot"}'
```

### 引用回复

```bash
curl -X POST http://astrbot:6185/api/v1/chat \
  -H "X-API-Key: abk_xxx" \
  -d '{"username":"user_a","session_id":"sid_abc","message":[{"type":"reply","message_id":42,"selected_text":"Bot说的话"},{"type":"plain","text":"我的回复"}],"config_id":"my_bot"}'
```

---

## 十、Flutter 项目结构

```
my_app/
├── lib/
│   ├── main.dart
│   ├── config/app_config.dart          ← AstrBot 地址/API Key/config_id
│   ├── models/chat_event.dart          ← SSE 事件模型
│   ├── models/message_part.dart        ← 消息段模型
│   ├── services/astrbot_client.dart    ← HTTP/SSE 客户端
│   ├── services/astrbot_ws_client.dart ← WebSocket 客户端（可选）
│   ├── services/file_service.dart      ← 上传/下载
│   ├── services/local_cache.dart       ← SQLite 缓存
│   ├── screens/chat_screen.dart        ← 主对话界面
│   ├── widgets/message_bubble.dart     ← 消息气泡
│   ├── widgets/image_viewer.dart       ← 图片预览
│   ├── widgets/audio_player.dart       ← 音频播放
│   └── utils/sse_parser.dart           ← SSE 逐行解析器
└── pubspec.yaml
```

**关键依赖**：

```yaml
dependencies:
  http: ^1.2.0            # SSE 流式读取
  web_socket_channel: ^3.0  # WebSocket（可选）
  sqflite: ^2.3.0          # 本地缓存
  image_picker: ^1.0.0     # 拍照/选图
  record: ^5.0.0           # 录音
  audioplayers: ^5.0.0     # 播放
  cached_network_image: ^3.3  # 图片缓存
  flutter_markdown: ^0.7    # Markdown 渲染
```

---

## 十一、开发路线

```
Phase 1 (1周): 最小可用
  ├── 创建 API Key + 配置文件
  ├── Flutter 骨架 + SSE 文本对话
  └── 单一 session 锁定

Phase 2 (1周): 多媒体
  ├── 图片/音频/文件 收发
  └── 媒体预览/播放

Phase 3 (1周): 增强体验
  ├── Markdown 渲染 + 引用回复
  ├── 断线重连 + 错误处理
  └── 本地 SQLite 缓存

Phase 4 (可选): 进阶
  ├── WebSocket 升级通道
  ├── 推送通知
  └── PWA/Web 版本
```
