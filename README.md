# Bot助手

基于 Flutter 的 [AstrBot](https://github.com/Soulter/AstrBot) Android 客户端。通过 WebSocket / SSE 连接自部署的 AstrBot 实例，支持文本、语音、图片、文件等多模态对话，内置流式输出、本地历史缓存、共享音频播放器与后台保活。

## 功能特性

- **多模态对话**：文本、语音消息（按住录制 / 拖动取消）、图片、文件发送与接收。
- **流式输出**：实时展示 bot 回复，配「三个点」打字动画。
- **工具调用展示**：可视化展示 `tool_call` / `tool_call_result`。
- **Markdown 渲染**：bot 文本回复支持 Markdown，可分享。
- **本地历史**：基于 sqflite 持久化消息，启动即全量加载（撤销旧版仅最新 10 条的限制），交由 SliverList 懒渲染，长列表首屏可靠置底。
- **共享音频播放器**：单一 `AudioPlayer` 单例驱动所有语音气泡——
  - 滚动聊天记录让播放中的气泡离开屏幕，播放不中断；
  - 天然互斥，同时只能播放一条；
  - bot 连续发多条语音时排队顺序播放。
- **语音自动播放**：右上角喇叭开关，开启后 bot 新发的语音自动播放，状态跨重启持久化。
- **后台保活**：前台服务 + 常驻通知，保持与服务器连接，后台不丢消息。
- **网络自愈**：连接异常断线时指数退避自动重连；监听网络变化触发重连。
- **暗黑模式**：跟随系统或手动切换主题。
- **配置管理**：服务器地址、API Key、配置 ID（名称或 UUID）、连接模式、昵称、主题。

## 技术栈

| 领域 | 选型 |
| --- | --- |
| 框架 | Flutter / Dart |
| 状态管理 | Riverpod 2.5（StateNotifierProvider） |
| 实时通信 | web_socket_channel（WS）、http（SSE） |
| 音频 | audioplayers 6（播放）、record 6（录制） |
| 本地存储 | sqflite（消息缓存）、shared_preferences（配置） |
| 后台保活 | flutter_foreground_task 8 |
| 媒体/附件 | image_picker、file_picker、cached_network_image、dio |
| 其他 | flutter_markdown、share_plus、connectivity_plus、permission_handler |

## 项目结构

```
lib/
├── config/            # AppConfig 全局常量（appName、默认服务器、重连参数等）
├── models/            # ChatEvent（事件模型）、LocalMessage（消息模型）
├── providers/
│   ├── chat_provider.dart      # 核心：连接、事件处理、消息状态机、历史加载
│   ├── config_provider.dart    # ConfigService 的 Riverpod 包装
│   └── audio_provider.dart     # 录音状态
├── services/
│   ├── astrbot_ws_client.dart  # WebSocket 客户端（心跳/重连）
│   ├── astrbot_sse_client.dart # SSE 客户端（HTTP 流式）
│   ├── audio_playback_service.dart # 共享音频播放器 + 队列（Riverpod StateNotifier）
│   ├── audio_service.dart      # 语音录制封装
│   ├── play_queue.dart         # 纯逻辑播放队列（可单测）
│   ├── cache_service.dart      # sqflite 消息缓存（带去重/迁移）
│   ├── config_service.dart     # 配置持久化
│   ├── file_service.dart       # 附件上传/下载
│   └── foreground_service.dart # 前台保活服务
├── screens/
│   ├── chat_screen.dart        # 主聊天页（气泡、录音、播放、流式动画）
│   ├── settings_screen.dart    # 设置页
│   └── setup_screen.dart       # 首次配置引导页
└── widgets/
    └── attachment_panel.dart   # 附件/录音面板
```

## 构建与运行

> 依赖 Flutter SDK（本项目开发环境为 Flutter 3.38.x，Dart ≥ 3.2）。

```bash
# 安装依赖
flutter pub get

# 连接设备调试
flutter run

# 构建 release APK（arm64）
flutter build apk --release --target-platform android-arm64
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

## 配置

首次启动进入引导页，填写：

- **服务器地址**：AstrBot 实例地址，如 `https://your-host`。
- **API Key**：AstrBot 开放 API 的密钥（`abk_` 开头）。
- **配置 ID**：可为配置名称或 UUID。名称会被解析为 UUID。
- **连接模式**：`sse`（SSE，默认，更稳定）或 `ws`（WebSocket）。WS 模式在接收大文件、大段文本时存在丢失及概率断连问题，建议使用 SSE。
- **昵称**：用于标识消息发送方。

配置保存在本地，可在设置页修改。连接成功后会自动获取并持久化 `session_id`。

## 关键设计

- **共享播放器解耦滚动**：音频播放器由 Riverpod `StateNotifier` 持有，生命周期独立于气泡 widget；气泡退化为纯视图，订阅播放状态。滚动回收气泡不影响播放，单播放器天然互斥。
- **消息缓存去重**：媒体 `raw` 与 `attachment_saved` 事件、文本 `complete`/`end` 事件的缓存写入用 sqflite 事务串行化，避免并发双写导致同一消息落两行；db 迁移时一次性清理存量重复。
- **WS 可靠性**：20s 心跳 + 12s pong 看门狗探测半开死连接，断线指数退避（1s→30s）重连，连接恢复后补发离线期间 pending 消息。

## 测试

```bash
flutter test
```

涵盖配置持久化（自动播放开关）、播放队列逻辑、消息模型等纯逻辑单元。

## 许可

本项目基于 [MIT License](LICENSE) 开源。
