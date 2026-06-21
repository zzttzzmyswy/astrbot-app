# 会话选择栏 + API Key 脱敏 设计

> 无人值守任务。用户明确:不审批,按我判断实现。本文档记录设计决策供后续追溯。

## 背景

- 客户端目前是**单会话**:`config_service` 存一个 `session_id`,首条消息后由服务端经 `session_id` 事件回传并落盘。本地消息表 `astrbot_messages.db.messages` **无 session_id 列**,`getMessages()` 取全部。
- 服务端 `PlatformSession`(session_id + display_name + creator)。API key 仅能 `GET /api/v1/chat/sessions`(列表)与「隐式创建」(用新/空 session_id 发消息 → 服务端 `uuid4()` 生成 + 经 `session_id` 事件回传)。**无 API-key 可访问的 delete/rename 端点**(db 层 `delete_platform_session`/`update_platform_session` 存在但未暴露到 `/api/v1/`)。

## 三个任务

1. 设置中 API Key 默认只显示前 10 个字符。
2. 聊天界面左→右滑拉出左侧会话选择栏:选择/创建/删除/自定义命名会话;初始名称在聊天开始后从 astrbot 服务器获取;最多 25 个。
3. 新增会话栏 UI 美化,与 APP 整体风格一致。

## 关键设计决策

### 多会话架构:本地注册表 + 服务端分配身份(无服务端改动)

不依赖服务端 delete/rename 端点(不存在且需改服务端+重启),改为**本地会话注册表**:

- `ChatSession { id, name?, createdAt, lastUsedAt }`,存 SharedPreferences JSON(`session_store`)。
- **身份来自服务端**:「新建会话」=清空当前 session_id → 下一条消息不带 session_id → 服务端 `uuid4()` 生成新会话 → 经 `session_id` 事件回传 → 客户端以该服务端 id 注册新会话。**「初始名称在聊天开始后从服务器获取」= 当 `session_id` 事件到达(即聊天开始)时,从服务端分配的 session_id 派生初始名(取前 8 位 hex,如 `a3f9b2c1`)**,用户可改名。
- 列表来源 = 本地注册表(不 merge 服务端列表,避免本地删除后被服务端列表「复活」;本 app 是唯一客户端)。
- **选择**:设 currentSessionId = 目标 id → 重连(发该 id → 服务端加载该对话历史)→ 加载该会话本地消息。
- **删除**:从注册表移除 + 删该会话本地消息(服务端 PlatformSession/对话成为孤儿,无害且对用户不可见)。删当前会话则切到另一个或新建。
- **改名**:仅改注册表 name(本地)。服务端 display_name 保持 null(无 API-key rename 端点)。
- **25 上限**:注册表层强制;达上限禁用新建并提示。

### 消息按 session_id 分区(必需,否则切换会话看不到各自历史)

服务端无 API-key 拉取会话历史的端点 → 切换会话只能靠本地按 session_id 分区存储。

- `messages` 表加 `session_id TEXT` 列,版本 4→5。
- `onUpgrade`:加列 + 回填 `UPDATE messages SET session_id = ?` 用当前 `_config.sessionId`(若 null 用 sentinel `'__legacy__'` 并种子一条「历史会话」注册表项,保证不丢消息)。
- 首启种子:注册表为空且 `_config.sessionId` 存在 → 种一条 {id: sessionId, name: 派生, ...},currentId = sessionId。把现有单会话平滑升级为「会话 #1」。
- `getMessages({sessionId})` / `insert` / `upsert` / `upsertBotText` / `hasAttachmentId` 全部按 session_id 过滤(去重逻辑也按会话作用域,避免跨会话误去重)。
- 新会话首条消息在服务端回传 session_id **之前**插入(session_id='') → `session_id` 事件到达时 `adoptOrphans(sessionId)` 把 `session_id=''` 的在途行认领到新 id。

### 任务1: API Key 脱敏

- 纯逻辑 `maskKey(String key, {int visible=10})`:前 10 位明文 + 掩码(`•`×min(剩余长度,12))。
- 设置页 API Key tile:副标题默认显示 `maskKey`;右侧眼睛 IconButton 切换明文/掩码;点 tile 仍进编辑对话框(编辑框明文可改)。其余 tile 不变。

## 模块划分(隔离、可测)

| 文件 | 职责 | 依赖 |
|---|---|---|
| `lib/util/key_mask.dart`(新) | `maskKey` 纯函数 | 无 |
| `lib/models/chat_session.dart`(新) | `ChatSession` + serde | 无 |
| `lib/services/session_store.dart`(新) | 注册表 CRUD/25 上限/种子;依赖 `SessionStorage` 抽象(便于单测) | `ChatSession` |
| `lib/services/prefs_storage.dart`(新) | `SessionStorage` 的 SharedPreferences 实现 | shared_preferences |
| `lib/services/cache_service.dart`(改) | 加 session_id 列 + 迁移 + 按会话过滤 + adoptOrphans/clearSession | sqflite, message |
| `lib/providers/chat_provider.dart`(改) | 集成 SessionStore;ChatState 增 sessions/current;create/select/delete/rename;session_id 事件注册 | 上述全部 |
| `lib/screens/settings_screen.dart`(改) | API Key tile 脱敏 + 眼睛切换 | key_mask |
| `lib/widgets/session_drawer.dart`(新) | 抽屉 UI | chat_provider |
| `lib/screens/chat_screen.dart`(改) | Scaffold.drawer + AppBar leading 菜单按钮 | session_drawer |

## UI(Task3 美化)

- 用 `Scaffold.drawer`(左边缘右滑自动拉出 + scrim + 动画,免手写手势)。AppBar leading 加菜单按钮(系统手势冲突时的兜底入口)。
- 抽屉宽 ~300,accent `0xFF5B4BD6`,圆角 16,明暗卡片色与聊天页一致(暗 `0xFF1C1C1E`/`0xFF212121`,亮 white/`0xFFF7F7F8`)。
- 头部:标题「会话」+ accent「新建」按钮。
- 列表行:圆形头像(首字符)、名称、副标题(短 id + 相对时间「3 分钟前」)、当前会话高亮(accent 左边条/填充底)、trailing `PopupMenuButton`(改名/删除)。
- 改名:对话框 TextField 预填。删除:确认对话框。25 上限:禁用新建 + SnackBar 提示。

## 测试(纯逻辑,dev 仅 flutter_test)

- `maskKey`:长 key 截断/掩码、短 key(<10)不全掩、空串。
- `ChatSession`:toJson/fromJson 往返。
- `SessionStore`:增删改查、按 lastUsedAt 排序、25 上限拒绝超员、首启种子(空注册表+已有 session_id → 种一条)、currentId 切换、删除当前会话切到另一个。
- 迁移/缓存层涉及平台 sqflite,靠构建+冒烟验证。

## 已知折中

- 删除/改名不落服务端(无 API-key 端点)→ 服务端留孤儿 PlatformSession/对话。单用户 app 不可见、无害。未来若加服务端端点可平滑接上(本地 name 为主,服务端 display_name 为辅)。
- 左边缘右滑可能与 Android 手势导航的返回手势争抢边缘 → 提供 leading 菜单按钮兜底。
