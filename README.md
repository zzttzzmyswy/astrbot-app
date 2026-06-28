# Bot助手 — AstrBot BotAPI 客户端

基于 Flutter 的 [AstrBot](https://github.com/Soulter/AstrBot) 移动 / 桌面客户端，通过 [astrbot_plugin_botapi](https://github.com/zzttzzmyswy/astrbot_plugin_botapi) 提供的 BotAPI 与自部署的 AstrBot 实例通信。

> ## ⚠️ 先装服务端插件
> 本应用是**客户端**，自身不能独立工作。使用前必须先在你的 AstrBot 服务端安装并启用插件 **[astrbot_plugin_botapi](https://github.com/zzttzzmyswy/astrbot_plugin_botapi)**（BotAPI 适配器），并在插件管理页生成一个 token。客户端用这个 token 连接。
>
> 插件安装与配置见插件仓库 README：<https://github.com/zzttzzmyswy/astrbot_plugin_botapi>

## 下载

最新版本（Android APK / Linux AppImage / Windows 单文件 exe）见 [Releases](https://github.com/zzttzzmyswy/astrbot-botapi-client/releases)。

| 平台 | 产物 | 用法 |
| --- | --- | --- |
| Android | `astrbot-vX.Y.Z.apk` | 安装 |
| Linux x64 | `astrbot-linux-vX.Y.Z.AppImage` | `chmod +x && ./xxx.AppImage` |
| Windows x64 | `astrbot-windows.exe` | 双击即运行（自解压） |

## 功能特性

- **多账户**：每个账户 = 一个 botapi token = 一个独立对话，账户间隔离。支持添加 / 重命名 / 切换 / 删除。
- **多模态**：文本、语音（按住录制 / 拖动取消）、图片、文件发送与接收。
- **流式 Markdown**：bot 回复边输出边渲染（标题 / 列表 / 代码块 / 表格 / 引用），无符号闪烁；消息内链接可点击，用系统默认浏览器打开。
- **思考与工具调用**：`thinking` 折叠气泡、`tool_status` 系统气泡，与实时一致地持久化到历史。
- **消息不丢**：SSE 实时 + 90s 空闲看门狗 + 恢复时历史合并 + 60s 周期对齐 + 回复后增量对齐，多层防漏。
- **本地历史**：sqflite 持久化，按 `server_id` 去重，启动加载最近 50 条，SliverList 懒渲染。
- **共享音频播放器**：单一播放器驱动所有语音气泡，滚动不中断、天然互斥、连续语音排队；可选自动播放。
- **后台保活**（移动端）：前台服务 + 常驻通知，保持连接不断；国产 ROM 电池白名单引导。
- **桌面单文件**：Linux AppImage、Windows 自解压 exe，下载即运行。
- **暗黑模式**：跟随系统或手动。

## 配置

首次启动添加一个账户：

- **服务器地址**：你的 AstrBot 实例地址，如 `https://your-host`。
- **Token**：在服务端 [astrbot_plugin_botapi](https://github.com/zzttzzmyswy/astrbot_plugin_botapi) 管理页生成的 token。

多账户可在左上角抽屉切换 / 管理。配置存本地，可在设置页修改。

## 架构

客户端走 BotAPI 五端点（详见 [插件 API 文档](https://github.com/zzttzzmyswy/astrbot_plugin_botapi/blob/main/docs/API.md)）：

- `POST /auth` — token 鉴权
- `POST /message` — 发消息
- `POST /upload` — 上传媒体拿 file_id
- `GET /stream?since=<id>` — SSE：实时 bot 回复（thinking / tool_status / text / media）
- `GET /history?since=&before=&limit=` — 历史拉取与断连补漏

```
lib/
├── models/            # account / botapi_event / history_row / message
├── services/
│   ├── botapi_http.dart       # /auth /message /upload /history (带重试)
│   ├── botapi_client.dart     # SSE 流客户端 (解析 / 退避重连 / 空闲看门狗)
│   ├── cache_service.dart     # sqflite 消息缓存 (server_id 去重 / 历史合并)
│   ├── account_store.dart     # 多账户注册表
│   ├── audio_playback_service.dart  # 共享播放器 + 队列
│   ├── update_service.dart    # 版本检查 / 下载
│   └── platform/              # 平台抽象:KeepAlive / Permission / UpdateApplier
├── providers/         # chat / config / audio / platform_providers (Riverpod)
├── screens/           # chat / setup / settings / account_editor
├── widgets/           # account_drawer / attachment_panel / oem_whitelist_dialog
└── util/              # retry / version / lru_cache / oem_whitelist
```

平台差异（前台保活、权限、更新安装）经 `lib/services/platform/` 的接口 + mobile/desktop 两套实现隔离，`Platform.is*` 只在 `platform_providers.dart` 出现一次，桌面安全降级、Android 不回归。

## 构建

> 依赖 Flutter 3.38.x / Dart ≥ 3.2。

```bash
flutter pub get

# Android
flutter build apk --release --target-platform android-arm64

# Linux 单文件 AppImage
bash scripts/build-appimage.sh        # 产出 build/astrbot_app-x86_64.AppImage

# Windows 单文件 exe
# 由 CI(.github/workflows/build-windows.yml) 在 windows-latest 上用 NSIS 打包,
# 推 v* tag 自动构建并挂 release。本机 Linux 无 MSVC,不能本地构建 Windows。
```

## 测试

```bash
flutter test      # 桌面平台实现、播放队列、消息模型等纯逻辑
flutter analyze   # 0 error
```

## 许可

[MIT License](LICENSE)。
