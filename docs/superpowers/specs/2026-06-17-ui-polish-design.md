# UI Polish & Fixes Design

**Date:** 2026-06-17
**Status:** approved

## Changes

### 1. Remove top-left avatar (`_Bar`)
- File: `lib/screens/chat_screen.dart`, class `_Bar`
- Delete `leading:` parameter from AppBar

### 2. Remove top-right mic button (`_Bar`)
- File: `lib/screens/chat_screen.dart`, class `_Bar`
- Delete `const VoiceRecorderButton()` from `actions` list
- Input bar mic↔send button stays — only AppBar mic removed

### 3. Markdown with caching (perf-safe)
- Already have `flutter_markdown: ^0.7.0` in pubspec
- Strategy: **async pre-build + widget cache**
  - Hash message content → cache key
  - Check `Map<String, Widget>` cache in `_ChatScreenState`
  - Cache miss: show plain `Text` placeholder → microtask builds `MarkdownBody` → store in cache → `setState`
  - Cache hit: reuse cached Widget directly (zero parse cost on scroll)
- `MarkdownBody` config:
  - `selectable: false`
  - GFM table support enabled
  - No image rendering (plain text for images)
  - `fitContent: true` to avoid unnecessary layout
- Quick guard: if text has no markdown syntax chars (`*`, `_`, `` ` ``, `[`, `#`, `|`, `>`), use plain `Text` — zero overhead for plain messages
- Cache lives in `_ChatScreenState`, cleared on disconnect/reconnect

### 4. Telegram-style attachment panel
- File: `lib/widgets/attachment_panel.dart`
- Visual changes:
  - Dark semi-transparent background with blur
  - Circular icon containers (56dp) with subtle fill
  - Outlined icon style
  - Labels below each icon
  - Equal spacing with Row + MainAxisAlignment.spaceEvenly
- Keep 3 options: Camera, Gallery, File (no new features)

### 5. Fix "connecting..." stuck state
- File: `lib/services/astrbot_ws_client.dart`
- `connect()` method:
  - Add 10-second timeout for `_channel!.ready`
  - On timeout: treat as disconnect → trigger `_scheduleReconnect()`
  - Add debug print for connection state changes
- File: `lib/screens/chat_screen.dart`, `_Bar`
  - Show "连接中..." only when `WsConnectionState.connecting`
  - Show "未连接" when `WsConnectionState.disconnected`
  - Show "在线" when `WsConnectionState.connected`

## Files Touched
1. `lib/screens/chat_screen.dart` — changes 1, 2, 3
2. `lib/widgets/attachment_panel.dart` — change 4
3. `lib/services/astrbot_ws_client.dart` — change 5
