# AstrBot Android 客户端 — 设计规格书

> 日期：2026-06-17
> 目标平台：Android（Flutter）
> 核心定位：单用户、极简、优雅美观、老人小孩友好

---

## 一、产品概述

为 AstrBot 打造专属 Android 聊天客户端。聊天界面参考 Telegram 风格，功能极简克制，让不熟悉智能设备的老人和小孩也能顺畅地与 AI 助手对话。

### 核心原则

- **简洁**：消息无长按菜单、无回复引用、无转发。只有核心互动。
- **语音优先**：长按录音，松开发送。用说话替代打字。
- **优雅美观**：Telegram 骨架 + 毛玻璃质感 + 渐变色气泡。
- **配置分离**：年轻人一次性配置好服务器/API Key，老人小孩打开直接聊。

---

## 二、系统架构

```
┌──────────────────────────────────────┐
│          App (Flutter)                │
│                                        │
│  ┌────────┐ ┌──────────┐ ┌─────────┐ │
│  │ UI 层  │ │ 服务层    │ │ 数据层   │ │
│  │ flutter │ │ WS 客户端 │ │ SQLite   │ │
│  │ chat ui │ │ 文件/录音  │ │ Prefs    │ │
│  └────────┘ └──────────┘ └─────────┘ │
└──────────────────────────────────────┘
         │ WebSocket / HTTP
         ▼
┌──────────────────────────────────────┐
│        AstrBot OpenAPI               │
│  /api/v1/chat/ws   ← WebSocket 聊天  │
│  /api/v1/file       ← 文件上传/下载   │
│  /api/v1/configs    ← 获取配置列表    │
│  认证: X-API-Key                     │
│  隔离: username 参数                  │
│  配置锁定: config_id 参数             │
└──────────────────────────────────────┘
```

### 技术选型

| 维度 | 选择 | 理由 |
|------|------|------|
| **框架** | Flutter | 参考方案文档推荐，可直接复用 Dart SDK 设计 |
| **聊天 UI** | flyerhq/flutter_chat_ui v2.11+ | 完整框架，主题可定制，后端解耦，2.2k+ star |
| **状态管理** | Riverpod | 编译时安全，独立 provider，适合异步事件流 |
| **通道** | WebSocket | 双向通信 + ping/pong 心跳 + 自动重连 |
| **本地存储** | SQLite + SharedPreferences | 消息历史 + 键值配置 |
| **网络检测** | connectivity_plus | 监听网络变化，触发自动重连 |

---

## 三、页面结构

### 3 个页面

```
首次引导页 ──（配置完成）──→ 主聊天页 ←──（齿轮图标）──→ 设置页
    ↑                         ↑
    └── 仅当无配置时显示        └── 每次打开 App 直达
```

### 3.1 首次引导页

**触发条件**：本地无配置（`is_configured != true`），仅首次显示。

**内容**：
- 昵称输入框
- 服务器地址输入框（如 `https://your-astrbot-host.example.com`）
- API Key 输入框
- Config ID 输入框
- 「开始聊天」按钮 → 保存配置 → 自动跳转聊天页

### 3.2 主聊天页

App 核心页面，老人小孩唯一使用的页面。

**顶栏**：
- Bot 头像（渐变色圆形）+ Bot 名称（从 configs API 获取）
- 在线/连接中状态指示
- 右侧齿轮图标 → 进入设置页

**消息列表**：
- 基于 flutter_chat_ui 的 Chat 组件
- Bot 气泡：毛玻璃半透明 + 微弱边框（`backdrop-filter: blur(12px)`）
- 用户气泡：蓝紫渐变色实体 + 投影
- 消息类型：文字 / 语音条 / 图片 / 文件
- 流式文本：Bot 回复实时追加，末尾闪烁光标
- 滚动：从底部开始，新消息自动滚到底部，上拉加载历史

**底部输入栏**：
- 附件按钮（📎） → 弹出附件面板
- 输入框（毛玻璃质感，圆角 18px）
- 麦克风按钮（🎤）→ 长按录音

**输入栏双模式**：
- **文字模式**：[📎] [输入框...] [🎤]
- **录音模式**：中央红色录音按钮，「松开发送 · 上滑取消」

**附件面板**（底部半屏浮层）：
- 📷 拍照（拍完自动上传发送）
- 🖼️ 相册
- 📁 文件

### 3.3 设置页

列表式布局：
- 修改昵称
- 修改服务器地址
- 修改 API Key
- 修改 Config ID
- 查看/清理缓存（显示缓存大小）
- 关于

修改后自动保存，返回聊天页自动重连。

---

## 四、WebSocket 通信

### 连接参数

```
ws://{server}/api/v1/chat/ws?api_key={api_key}
```

### 上行消息格式

```json
{"t":"send","username":"{nickname}","session_id":"{sid}","message":[...],"config_id":"{id}"}
{"t":"ping"}
```

### 下行事件类型

| 事件 | 处理 |
|------|------|
| `plain` | 流式追加文本到当前 Bot 气泡 |
| `image` | 触发附件下载 → 插入图片气泡 |
| `record` | 触发附件下载 → 插入语音气泡 |
| `file` | 触发附件下载 → 插入文件气泡 |
| `attachment_saved` | 记录附件 ID |
| `message_saved` | Bot 消息持久化完成 |
| `user_message_saved` | 用户消息持久化完成 |
| `complete` | 标记当前气泡完成 |
| `end` | 关闭本次响应流 |
| `error` | 显示错误提示 |
| `pong` | 心跳响应 |

### 心跳与重连

- **心跳间隔**：30 秒 ping/pong
- **重连策略**：指数退避 1s → 2s → 4s → 8s → 16s → 30s（封顶），无限重试
- **网络感知**：依赖 connectivity_plus，网络恢复时自动触发重连
- **消息队列**：断连期间发送的消息入队缓存，重连后自动发出

### 用户侧体验

| 场景 | 表现 |
|------|------|
| 消息发送中 | 气泡显示加载动画 |
| WS 断开 | 顶栏状态变为「连接中...」，输入栏仍可用 |
| 断连时发消息 | 消息入队，重连后自动发 |
| 重连成功 | 顶栏恢复「在线」，缓存消息发送 |
| Bot 响应异常 | 气泡内显示「响应出错，请重试」 |
| 无网络 | 提示「当前无网络连接」 |

---

## 五、多媒体

### 语音消息

- 长按麦克风按钮 → 开始录音（WAV 格式）
- 上滑 → 取消发送
- 松开 → 停止录音 → 上传 `/api/v1/file` → 获取 `attachment_id` → 发送 `{type: "record", attachment_id: "..."}`
- Bot 语音气泡：显示播放按钮 + 波形进度条，点击播放

### 图片/拍照

- 拍完照自动上传 → 获取 `attachment_id` → 自动发送 `{type: "image", attachment_id: "..."}`
- 相册选择同理

### Bot 媒体接收

- SSE 收到 `{type:"image","data":"[IMAGE]uuid.jpg"}` → 调用 `/api/v1/file?attachment_id=xxx` 下载
- 下载完成后缓存本地，显示在气泡中

---

## 六、本地存储

### SQLite — 消息缓存

```sql
CREATE TABLE messages (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  msg_type      TEXT    NOT NULL,  -- 'text' | 'voice' | 'image' | 'file'
  content       TEXT,              -- 文本内容（媒体类型存本地路径）
  attachment_id TEXT,              -- AstrBot 附件 ID
  is_from_me    INTEGER NOT NULL,  -- 1=用户, 0=Bot
  status        TEXT    NOT NULL,  -- 'pending' | 'sent' | 'error'
  created_at    INTEGER NOT NULL   -- Unix timestamp ms
);
```

### SharedPreferences — 配置

| Key | 说明 | 示例 |
|-----|------|------|
| `nickname` | 用户昵称 | `"小明"` |
| `server_url` | AstrBot 地址 | `"https://your-astrbot-host.example.com"` |
| `api_key` | API Key | `"abk_Qz97LB..."` |
| `config_id` | Bot 配置 ID | `"my_bot"` |
| `session_id` | 当前 session | `"sid_abc123"` |
| `is_configured` | 是否已完成引导 | `true` |

### 文件缓存

- 目录：`app_cache/attachments/{attachment_id}.{ext}`
- 录音草稿：`app_cache/draft_record.wav`，发送成功后删除
- 自动清理：App 启动时检查，删除 7 天前的缓存文件
- 手动清理：设置页「清理缓存」按钮 → 显示大小 → 确认清理

### Bot 文件保存

- 文件气泡增加「保存」按钮 → 复制到 `{Download}/AstrBot/{filename}`
- 图片长按 → 弹出「保存到相册」选项
- 保存成功 Toast 提示「已保存到下载目录」

---

## 七、项目结构

```
astrbot_app/
├── lib/
│   ├── main.dart                      # App 入口 + Riverpod ProviderScope
│   ├── config/
│   │   └── app_config.dart            # 配置常量与默认值
│   ├── models/
│   │   ├── chat_event.dart            # WebSocket 事件模型
│   │   └── message.dart               # 本地消息模型
│   ├── services/
│   │   ├── astrbot_ws_client.dart     # WebSocket 客户端 + 重连逻辑
│   │   ├── file_service.dart          # 上传/下载
│   │   ├── audio_service.dart         # 录音/播放
│   │   ├── config_service.dart        # SharedPreferences 读写
│   │   └── cache_service.dart         # SQLite 消息缓存 + 附件缓存管理
│   ├── providers/
│   │   ├── chat_provider.dart         # 消息列表 + WS 状态
│   │   ├── config_provider.dart       # 配置状态
│   │   └── audio_provider.dart        # 录音状态
│   ├── screens/
│   │   ├── setup_screen.dart          # 首次引导页
│   │   ├── chat_screen.dart           # 主聊天页
│   │   └── settings_screen.dart       # 设置页
│   └── widgets/
│       ├── voice_recorder.dart        # 自定义录音按钮组件
│       └── attachment_panel.dart      # 附件面板组件
├── pubspec.yaml
└── android/
    └── ...                            # Android 原生配置
```

### 关键依赖

```yaml
dependencies:
  flutter_chat_ui: ^2.11.0       # 聊天 UI 框架
  flutter_chat_core: ^2.0.0      # Chat 核心模型
  flutter_riverpod: ^2.5.0       # 状态管理
  web_socket_channel: ^3.0.0     # WebSocket
  http: ^1.2.0                   # HTTP 请求
  sqflite: ^2.3.0                # SQLite
  shared_preferences: ^2.3.0     # 键值存储
  connectivity_plus: ^6.0.0      # 网络检测
  image_picker: ^1.0.0           # 拍照/选图
  record: ^5.0.0                 # 录音
  audioplayers: ^6.0.0           # 音频播放
  path_provider: ^2.1.0          # 文件路径
  cached_network_image: ^3.3.0   # 图片缓存
  permission_handler: ^11.0.0    # 权限管理
```

---

## 八、开发路线

```
Phase 1: 最小可用
  ├── Flutter 项目骨架 + main.dart
  ├── 首次引导页（配置录入 + 保存）
  ├── WebSocket 聊天（文本 + 流式显示）
  ├── 基于 flutter_chat_ui 的聊天页
  └── 重连机制

Phase 2: 多媒体
  ├── 录音 + 发送语音消息
  ├── 拍照 + 图片收发
  ├── 语音/图片气泡渲染
  └── 附件下载 + 缓存

Phase 3: 完善
  ├── 设置页
  ├── 文件类型消息（保存到下载目录）
  ├── 缓存清理（自动 + 手动）
  ├── 错误处理 + 网络异常提示
  └── SQLite 消息历史缓存

Phase 4: 视觉打磨
  ├── 毛玻璃效果（BackdropFilter）
  ├── 渐变色气泡
  ├── 背景光晕
  └── 动画过渡
```

---

## 九、Apk 构建设置

- **最低 SDK**：Android 5.0 (API 21)
- **目标 SDK**：Android 14 (API 34)
- **架构**：arm64-v8a
- **包名**：`top.zztweb.astrbot`
- **应用名**：AstrBot 助手
