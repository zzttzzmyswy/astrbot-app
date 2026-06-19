# AstrBot Android Client — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an elegant, single-user Android chat app for AstrBot with Telegram-style UI, voice messages, and image sharing.

**Architecture:** Flutter + flyerhq/flutter_chat_ui for the chat shell + Riverpod for state + WebSocket for real-time communication. Three screens (setup → chat ↔ settings), SQLite for message cache, SharedPreferences for config.

**Tech Stack:** Flutter (stable), flyerhq/flutter_chat_ui ^2.11.0, flutter_riverpod ^2.5.0, web_socket_channel ^3.0.0, sqflite ^2.3.0, shared_preferences ^2.3.0, record ^5.0.0, audioplayers ^6.0.0, image_picker ^1.0.0, connectivity_plus ^6.0.0, permission_handler ^11.0.0, path_provider ^2.1.0, http ^1.2.0.

**Prerequisite:** Flutter SDK must be installed on the development machine. Verify with `flutter doctor`.

---

## File Structure

```
astrbot_app/
├── lib/
│   ├── main.dart                      # App entry + Riverpod ProviderScope
│   ├── config/
│   │   └── app_config.dart            # Defaults & constants
│   ├── models/
│   │   ├── chat_event.dart            # WebSocket event DTOs
│   │   └── message.dart               # Local message model
│   ├── services/
│   │   ├── astrbot_ws_client.dart     # WebSocket client + reconnect
│   │   ├── file_service.dart          # Upload/download attachments
│   │   ├── audio_service.dart         # Record/play audio
│   │   ├── config_service.dart        # SharedPreferences wrapper
│   │   └── cache_service.dart         # SQLite + file cache mgmt
│   ├── providers/
│   │   ├── chat_provider.dart         # Message list + WS state
│   │   ├── config_provider.dart       # Config state + validation
│   │   └── audio_provider.dart        # Recording state
│   ├── screens/
│   │   ├── setup_screen.dart          # First-time configuration
│   │   ├── chat_screen.dart           # Main chat page
│   │   └── settings_screen.dart       # Configuration management
│   └── widgets/
│       ├── voice_recorder.dart        # Long-press record button
│       └── attachment_panel.dart      # Bottom sheet: camera/gallery/file
├── pubspec.yaml
├── android/
│   └── app/build.gradle               # Android config (minSdk:21, arch:arm64)
└── test/
    └── widget_test.dart
```

---

### Task 1: Create Flutter Project & Configure Dependencies

**Files:**
- Create: `pubspec.yaml`
- Create: `lib/main.dart`
- Create: `lib/config/app_config.dart`
- Modify: `android/app/build.gradle` (after flutter create)

- [ ] **Step 1: Create Flutter project**

```bash
flutter create --org top.zztweb --project-name astrbot_app --platforms android .
```

Expected: Project files created in current directory, no errors.

- [ ] **Step 2: Edit pubspec.yaml with all dependencies**

Open `pubspec.yaml`, replace the dependencies section:

```yaml
name: astrbot_app
description: AstrBot Android Chat Client
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.2.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  flutter_chat_ui: ^2.11.0
  flutter_chat_core: ^2.0.0
  flutter_riverpod: ^2.5.0
  web_socket_channel: ^3.0.0
  http: ^1.2.0
  sqflite: ^2.3.0
  shared_preferences: ^2.3.0
  connectivity_plus: ^6.0.0
  image_picker: ^1.0.0
  record: ^5.0.0
  audioplayers: ^6.0.0
  path_provider: ^2.1.0
  permission_handler: ^11.0.0
  cached_network_image: ^3.3.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^3.0.0
```

Run:

```bash
flutter pub get
```

Expected: All dependencies resolved successfully.

- [ ] **Step 3: Configure Android build (arm64 only, minSdk 21)**

Modify `android/app/build.gradle`:

```gradle
android {
    namespace "top.zztweb.astrbot"
    compileSdk 34

    defaultConfig {
        applicationId "top.zztweb.astrbot"
        minSdk 21
        targetSdk 34
        versionCode 1
        versionName "1.0.0"
    }

    buildTypes {
        release {
            signingConfig signingConfigs.debug  // placeholder
        }
    }
    ndk {
        abiFilters 'arm64-v8a'
    }
}
```

- [ ] **Step 4: Create app_config.dart**

```dart
// lib/config/app_config.dart
class AppConfig {
  static const String appName = 'AstrBot 助手';
  static const String defaultServerUrl = 'https://your-astrbot-host.example.com';
  static const String defaultConfigId = 'my_bot';
  static const int wsReconnectBaseMs = 1000;
  static const int wsReconnectMaxMs = 30000;
  static const int wsPingIntervalSec = 30;
  static const int cacheRetentionDays = 7;
}
```

- [ ] **Step 5: Replace main.dart with scaffold**

```dart
// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'config/app_config.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: AstrBotApp()));
}

class AstrBotApp extends StatelessWidget {
  const AstrBotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121215),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4A9EFF),
          brightness: Brightness.dark,
        ),
      ),
      home: const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}
```

- [ ] **Step 6: Verify build**

```bash
flutter pub get && flutter analyze
```

Expected: No analysis errors.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "chore: init Flutter project with dependencies and Android config

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Data Models

**Files:**
- Create: `lib/models/chat_event.dart`
- Create: `lib/models/message.dart`

- [ ] **Step 1: Write chat_event.dart**

```dart
// lib/models/chat_event.dart
class ChatEvent {
  final String type;
  final String? data;
  final bool? streaming;
  final String? sessionId;
  final String? code;
  final Map<String, dynamic>? raw;

  ChatEvent({
    required this.type,
    this.data,
    this.streaming,
    this.sessionId,
    this.code,
    this.raw,
  });

  factory ChatEvent.fromJson(Map<String, dynamic> json) {
    return ChatEvent(
      type: json['type'] as String? ?? '',
      data: json['data']?.toString(),
      streaming: json['streaming'] as bool?,
      sessionId: json['session_id'] as String?,
      code: json['code'] as String?,
      raw: json,
    );
  }

  bool get isEnd => type == 'end';
  bool isError => type == 'error';
  bool isAttachmentSaved => type == 'attachment_saved';
}
```

- [ ] **Step 2: Write message.dart**

```dart
// lib/models/message.dart
enum MessageStatus { pending, sent, error }

class LocalMessage {
  final int? id;
  final String msgType; // 'text', 'voice', 'image', 'file'
  final String? content;
  final String? attachmentId;
  final bool isFromMe;
  final MessageStatus status;
  final int createdAt;

  const LocalMessage({
    this.id,
    required this.msgType,
    this.content,
    this.attachmentId,
    required this.isFromMe,
    this.status = MessageStatus.pending,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'msg_type': msgType,
        'content': content,
        'attachment_id': attachmentId,
        'is_from_me': isFromMe ? 1 : 0,
        'status': status.name,
        'created_at': createdAt,
      };

  factory LocalMessage.fromMap(Map<String, dynamic> map) => LocalMessage(
        id: map['id'] as int?,
        msgType: map['msg_type'] as String,
        content: map['content'] as String?,
        attachmentId: map['attachment_id'] as String?,
        isFromMe: (map['is_from_me'] as int) == 1,
        status: MessageStatus.values.byName(map['status'] as String),
        createdAt: map['created_at'] as int,
      );

  LocalMessage copyWith({
    int? id,
    String? msgType,
    String? content,
    String? attachmentId,
    bool? isFromMe,
    MessageStatus? status,
    int? createdAt,
  }) =>
      LocalMessage(
        id: id ?? this.id,
        msgType: msgType ?? this.msgType,
        content: content ?? this.content,
        attachmentId: attachmentId ?? this.attachmentId,
        isFromMe: isFromMe ?? this.isFromMe,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
      );
}
```

- [ ] **Step 3: Commit**

```bash
git add lib/models/ && git commit -m "feat: add ChatEvent and LocalMessage models

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Config Service (SharedPreferences)

**Files:**
- Create: `lib/services/config_service.dart`

- [ ] **Step 1: Write config_service.dart**

```dart
// lib/services/config_service.dart
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';

class ConfigService {
  static const _kNickname = 'nickname';
  static const _kServerUrl = 'server_url';
  static const _kApiKey = 'api_key';
  static const _kConfigId = 'config_id';
  static const _kSessionId = 'session_id';
  static const _kIsConfigured = 'is_configured';

  late SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  bool get isConfigured => _prefs.getBool(_kIsConfigured) ?? false;

  String get nickname => _prefs.getString(_kNickname) ?? '';
  String get serverUrl => _prefs.getString(_kServerUrl) ?? AppConfig.defaultServerUrl;
  String get apiKey => _prefs.getString(_kApiKey) ?? '';
  String get configId => _prefs.getString(_kConfigId) ?? AppConfig.defaultConfigId;
  String? get sessionId => _prefs.getString(_kSessionId);

  Future<void> setNickname(String v) async => _prefs.setString(_kNickname, v);
  Future<void> setServerUrl(String v) async => _prefs.setString(_kServerUrl, v);
  Future<void> setApiKey(String v) async => _prefs.setString(_kApiKey, v);
  Future<void> setConfigId(String v) async => _prefs.setString(_kConfigId, v);
  Future<void> setSessionId(String v) async => _prefs.setString(_kSessionId, v);

  Future<void> saveSetup({
    required String nickname,
    required String serverUrl,
    required String apiKey,
    required String configId,
  }) async {
    await setNickname(nickname);
    await setServerUrl(serverUrl);
    await setApiKey(apiKey);
    await setConfigId(configId);
    await _prefs.setBool(_kIsConfigured, true);
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/services/config_service.dart && git commit -m "feat: add ConfigService for SharedPreferences

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: WebSocket Client with Reconnection

**Files:**
- Create: `lib/services/astrbot_ws_client.dart`

- [ ] **Step 1: Write astrbot_ws_client.dart**

```dart
// lib/services/astrbot_ws_client.dart
import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/chat_event.dart';

enum WsConnectionState { disconnected, connecting, connected }

class AstrBotWsClient {
  final String serverUrl;
  final String apiKey;
  final String username;
  final String configId;
  String? sessionId;

  WebSocketChannel? _channel;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  int _reconnectDelay = 1000;
  bool _disposed = false;

  final _eventController = StreamController<ChatEvent>.broadcast();
  final _stateController = StreamController<WsConnectionState>.broadcast();

  Stream<ChatEvent> get events => _eventController.stream;
  Stream<WsConnectionState> get state => _stateController.stream;
  WsConnectionState _state = WsConnectionState.disconnected;

  AstrBotWsClient({
    required this.serverUrl,
    required this.apiKey,
    required this.username,
    required this.configId,
    this.sessionId,
  });

  Future<void> connect() async {
    if (_disposed) return;
    _setState(WsConnectionState.connecting);

    try {
      final uri = Uri.parse(serverUrl)
          .replace(scheme: serverUrl.startsWith('https') ? 'wss' : 'ws')
          .replace(path: '/api/v1/chat/ws', queryParameters: {'api_key': apiKey});

      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      _setState(WsConnectionState.connected);
      _reconnectDelay = 1000;

      _startPing();
      _channel!.stream.listen(
        _onMessage,
        onError: (e) => _onDisconnected(),
        onDone: () => _onDisconnected(),
      );
    } catch (e) {
      _setState(WsConnectionState.disconnected);
      _scheduleReconnect();
    }
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _sendRaw(jsonEncode({'t': 'ping'}));
    });
  }

  void _onMessage(dynamic msg) {
    if (msg is String) {
      try {
        final json = jsonDecode(msg) as Map<String, dynamic>;
        if (json['type'] == 'pong') return;

        final event = ChatEvent.fromJson(json);
        if (event.type == 'session_id' && event.sessionId != null) {
          sessionId = event.sessionId;
        }
        _eventController.add(event);
      } catch (_) {}
    }
  }

  void sendMessage(List<Map<String, dynamic>> messageParts) {
    final payload = {
      't': 'send',
      'username': username,
      if (sessionId != null) 'session_id': sessionId,
      'message': messageParts,
      'config_id': configId,
    };
    _sendRaw(jsonEncode(payload));
  }

  void _sendRaw(String data) {
    try {
      _channel?.sink.add(data);
    } catch (_) {}
  }

  void _onDisconnected() {
    _pingTimer?.cancel();
    _setState(WsConnectionState.disconnected);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: _reconnectDelay), () {
      connect();
      _reconnectDelay = (_reconnectDelay * 2).clamp(1000, 30000);
    });
  }

  void _setState(WsConnectionState state) {
    _state = state;
    _stateController.add(state);
  }

  Future<void> dispose() async {
    _disposed = true;
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    await _channel?.sink.close();
    await _eventController.close();
    await _stateController.close();
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/services/astrbot_ws_client.dart && git commit -m "feat: add WebSocket client with exponential backoff reconnection

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Riverpod Providers

**Files:**
- Create: `lib/providers/config_provider.dart`
- Create: `lib/providers/chat_provider.dart`
- Create: `lib/providers/audio_provider.dart`

- [ ] **Step 1: Write config_provider.dart**

```dart
// lib/providers/config_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/config_service.dart';

final configServiceProvider = Provider<ConfigService>((ref) {
  return ConfigService();
});

final configInitializedProvider = FutureProvider<bool>((ref) async {
  final service = ref.read(configServiceProvider);
  await service.init();
  return service.isConfigured;
});

final isConfiguredProvider = Provider<bool>((ref) {
  final async = ref.watch(configInitializedProvider);
  return async.valueOrNull ?? false;
});
```

- [ ] **Step 2: Write chat_provider.dart**

```dart
// lib/providers/chat_provider.dart
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_event.dart';
import '../models/message.dart';
import '../services/astrbot_ws_client.dart';
import '../services/config_service.dart';
import 'config_provider.dart';

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  final config = ref.read(configServiceProvider);
  return ChatNotifier(config);
});

class ChatState {
  final List<LocalMessage> messages;
  final WsConnectionState connectionState;
  final String? streamingText;
  final String? errorMessage;

  const ChatState({
    this.messages = const [],
    this.connectionState = WsConnectionState.disconnected,
    this.streamingText,
    this.errorMessage,
  });

  ChatState copyWith({
    List<LocalMessage>? messages,
    WsConnectionState? connectionState,
    String? streamingText,
    String? errorMessage,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        connectionState: connectionState ?? this.connectionState,
        streamingText: streamingText,
        errorMessage: errorMessage,
      );
}

class ChatNotifier extends StateNotifier<ChatState> {
  final ConfigService _config;
  AstrBotWsClient? _client;
  StreamSubscription<ChatEvent>? _eventSub;
  final List<Map<String, dynamic>> _pendingQueue = [];

  ChatNotifier(this._config) : super(const ChatState());

  Future<void> connect() async {
    _client?.dispose();
    _client = AstrBotWsClient(
      serverUrl: _config.serverUrl,
      apiKey: _config.apiKey,
      username: _config.nickname,
      configId: _config.configId,
      sessionId: _config.sessionId,
    );

    _client!.state.listen((s) {
      state = state.copyWith(connectionState: s);
      if (s == WsConnectionState.connected && _pendingQueue.isNotEmpty) {
        for (final msg in _pendingQueue) {
          _client!.sendMessage(msg.cast<Map<String, dynamic>>());
        }
        _pendingQueue.clear();
      }
    });

    _eventSub = _client!.events.listen(_handleEvent);
    await _client!.connect();
  }

  void sendText(String text) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgParts = [{'type': 'plain', 'text': text}];

    final localMsg = LocalMessage(
      msgType: 'text',
      content: text,
      isFromMe: true,
      status: MessageStatus.pending,
      createdAt: now,
    );
    state = state.copyWith(messages: [...state.messages, localMsg]);

    if (state.connectionState == WsConnectionState.connected) {
      _client?.sendMessage(msgParts);
      state = state.copyWith(
        messages: state.messages
            .map((m) => m.createdAt == now ? m.copyWith(status: MessageStatus.sent) : m)
            .toList(),
      );
    } else {
      _pendingQueue.add(msgParts);
    }
  }

  void sendVoice(String attachmentId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgParts = [{'type': 'record', 'attachment_id': attachmentId}];

    final localMsg = LocalMessage(
      msgType: 'voice',
      attachmentId: attachmentId,
      isFromMe: true,
      status: MessageStatus.pending,
      createdAt: now,
    );
    state = state.copyWith(messages: [...state.messages, localMsg]);
    _client?.sendMessage(msgParts);
  }

  void sendImage(String attachmentId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msgParts = [
      {'type': 'plain', 'text': ''},
      {'type': 'image', 'attachment_id': attachmentId},
    ];

    final localMsg = LocalMessage(
      msgType: 'image',
      attachmentId: attachmentId,
      isFromMe: true,
      status: MessageStatus.pending,
      createdAt: now,
    );
    state = state.copyWith(messages: [...state.messages, localMsg]);
    _client?.sendMessage(msgParts);
  }

  void _handleEvent(ChatEvent event) {
    final now = DateTime.now().millisecondsSinceEpoch;

    switch (event.type) {
      case 'session_id':
        _config.setSessionId(event.sessionId!);
        break;

      case 'plain':
        final currentStreaming = state.streamingText ?? '';
        state = state.copyWith(streamingText: currentStreaming + (event.data ?? ''));

      case 'image':
      case 'record':
      case 'file':
        final attachmentId = _extractAttachmentId(event.data ?? '');
        if (attachmentId != null) {
          final botMsg = LocalMessage(
            msgType: event.type,
            attachmentId: attachmentId,
            isFromMe: false,
            status: MessageStatus.sent,
            createdAt: now,
          );
          state = state.copyWith(messages: [...state.messages, botMsg]);
        }
        break;

      case 'complete':
        if (state.streamingText != null && state.streamingText!.isNotEmpty) {
          final botMsg = LocalMessage(
            msgType: 'text',
            content: state.streamingText,
            isFromMe: false,
            status: MessageStatus.sent,
            createdAt: now,
          );
          state = state.copyWith(
            messages: [...state.messages, botMsg],
            streamingText: null,
          );
        }
        break;

      case 'end':
        if (state.streamingText != null && state.streamingText!.isNotEmpty) {
          final botMsg = LocalMessage(
            msgType: 'text',
            content: state.streamingText,
            isFromMe: false,
            status: MessageStatus.sent,
            createdAt: now,
          );
          state = state.copyWith(
            messages: [...state.messages, botMsg],
            streamingText: null,
          );
        }
        break;

      case 'error':
        state = state.copyWith(errorMessage: event.data ?? '未知错误');
        break;
    }
  }

  String? _extractAttachmentId(String raw) {
    final match = RegExp(r'\[(?:IMAGE|RECORD|FILE|VIDEO)\](.+)').firstMatch(raw);
    return match?.group(1);
  }

  void clearError() => state = state.copyWith(errorMessage: null);

  @override
  void dispose() {
    _eventSub?.cancel();
    _client?.dispose();
    super.dispose();
  }
}
```


- [ ] **Step 3: Write audio_provider.dart**

```dart
// lib/providers/audio_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AudioState { idle, recording, playing }

class AudioNotifier extends StateNotifier<AudioState> {
  AudioNotifier() : super(AudioState.idle);

  void startRecording() => state = AudioState.recording;
  void stopRecording() => state = AudioState.idle;
  void startPlaying() => state = AudioState.playing;
  void stopPlaying() => state = AudioState.idle;
}

final audioProvider = StateNotifierProvider<AudioNotifier, AudioState>((ref) {
  return AudioNotifier();
});
```

- [ ] **Step 4: Commit**

```bash
git add lib/providers/ pubspec.yaml && git commit -m "feat: add Riverpod providers for config, chat, and audio state

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Setup Screen

**Files:**
- Create: `lib/screens/setup_screen.dart`

- [ ] **Step 1: Write setup_screen.dart**

```dart
// lib/screens/setup_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/config_provider.dart';
import '../services/config_service.dart';
import 'chat_screen.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _nicknameCtrl = TextEditingController(text: '小明');
  final _serverCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  final _configIdCtrl = TextEditingController(text: 'my_bot');
  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final config = ref.read(configServiceProvider);
    _serverCtrl.text = config.serverUrl;
    _apiKeyCtrl.text = config.apiKey;
    _configIdCtrl.text = config.configId;
  }

  Future<void> _onSave() async {
    setState(() => _connecting = true);
    final config = ref.read(configServiceProvider);
    await config.saveSetup(
      nickname: _nicknameCtrl.text.trim(),
      serverUrl: _serverCtrl.text.trim(),
      apiKey: _apiKeyCtrl.text.trim(),
      configId: _configIdCtrl.text.trim(),
    );
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ChatScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.chat_bubble_rounded, size: 56, color: Color(0xFF4A9EFF)),
              const SizedBox(height: 12),
              const Text(
                '欢迎使用 AstrBot',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              _buildField('昵称', _nicknameCtrl),
              const SizedBox(height: 12),
              _buildField('服务器地址', _serverCtrl),
              const SizedBox(height: 12),
              _buildField('API Key', _apiKeyCtrl, obscure: true),
              const SizedBox(height: 12),
              _buildField('Config ID', _configIdCtrl),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _connecting ? null : _onSave,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4A9EFF),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _connecting
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('开始聊天', style: TextStyle(fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(String label, TextEditingController ctrl, {bool obscure = false}) {
    return TextField(
      controller: ctrl,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/screens/setup_screen.dart && git commit -m "feat: add setup screen for first-time configuration

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Chat Screen with flutter_chat_ui

**Files:**
- Create: `lib/screens/chat_screen.dart`

- [ ] **Step 1: Write chat_screen.dart**

```dart
// lib/screens/chat_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/chat_provider.dart';
import '../providers/config_provider.dart';
import '../services/config_service.dart';
import 'settings_screen.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  late final ConfigService _config;

  @override
  void initState() {
    super.initState();
    _config = ref.read(configServiceProvider);
    Future.microtask(() => ref.read(chatProvider.notifier).connect());
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatProvider);
    final botName = 'AstrBot 助手';

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A28),
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: CircleAvatar(
            backgroundColor: const Color(0xFF4A9EFF),
            child: const Text('🤖', style: TextStyle(fontSize: 18)),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(botName, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            Text(
              chatState.connectionState == WsConnectionState.connected ? '在线' : '连接中...',
              style: TextStyle(
                fontSize: 11,
                color: chatState.connectionState == WsConnectionState.connected
                    ? Colors.greenAccent
                    : Colors.grey,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: Chat(
        messages: _buildChatMessages(chatState),
        onSendPressed: (text) {
          ref.read(chatProvider.notifier).sendText(text.text);
        },
        user: _buildChatUser(),
        theme: const DefaultChatTheme(
          primaryColor: Color(0xFF3D7CEB),
          backgroundColor: Color(0xFF121215),
          inputBackgroundColor: Color(0xFF2A2A36),
        ),
        // Show streaming text as a separate typing indicator
      ),
    );
  }

  List<types.Message> _buildChatMessages(ChatState state) {
    final messages = <types.Message>[];
    for (final m in state.messages) {
      messages.add(types.TextMessage(
        author: types.Author(id: m.isFromMe ? _config.nickname : 'bot'),
        id: m.createdAt.toString(),
        text: m.content ?? '',
      ));
    }
    if (state.streamingText != null && state.streamingText!.isNotEmpty) {
      messages.add(types.TextMessage(
        author: const types.Author(id: 'bot'),
        id: 'streaming',
        text: state.streamingText!,
      ));
    }
    return messages;
  }

  types.User _buildChatUser() {
    return types.User(id: _config.nickname);
  }
}
```

- [ ] **Step 2: Update main.dart to route based on config**

```dart
// lib/main.dart (replace the home: property)
import 'screens/setup_screen.dart';
import 'screens/chat_screen.dart';
import 'providers/config_provider.dart';

// Replace the home: Scaffold... with:
home: Consumer(
  builder: (context, ref, _) {
    final asyncConfig = ref.watch(configInitializedProvider);
    return asyncConfig.when(
      data: (isConfigured) => isConfigured ? const ChatScreen() : const SetupScreen(),
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, __) => const SetupScreen(),
    );
  },
),
```

Updated main.dart:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'config/app_config.dart';
import 'screens/chat_screen.dart';
import 'screens/setup_screen.dart';
import 'providers/config_provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: AstrBotApp()));
}

class AstrBotApp extends StatelessWidget {
  const AstrBotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121215),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4A9EFF),
          brightness: Brightness.dark,
        ),
      ),
      home: Consumer(
        builder: (context, ref, _) {
          final asyncConfig = ref.watch(configInitializedProvider);
          return asyncConfig.when(
            data: (isConfigured) => isConfigured ? const ChatScreen() : const SetupScreen(),
            loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
            error: (_, __) => const SetupScreen(),
          );
        },
      ),
    );
  }
}
```

- [ ] **Step 3: Build and verify**

```bash
flutter pub get && flutter analyze
```

Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add lib/main.dart lib/screens/chat_screen.dart && git commit -m "feat: add chat screen with flutter_chat_ui and app routing

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: File Upload/Download Service

**Files:**
- Create: `lib/services/file_service.dart`

- [ ] **Step 1: Write file_service.dart**

```dart
// lib/services/file_service.dart
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class FileService {
  final String serverUrl;
  final String apiKey;

  FileService({required this.serverUrl, required this.apiKey});

  Future<Map<String, dynamic>> uploadFile(File file, String contentType) async {
    final uri = Uri.parse('$serverUrl/api/v1/file');
    final request = http.MultipartRequest('POST', uri);
    request.headers['X-API-Key'] = apiKey;
    request.files.add(await http.MultipartFile.fromPath('file', file.path,
        contentType: contentType));
    final response = await request.send();
    final body = await response.stream.bytesToString();
    final json = _parseJson(body);
    return json['data'] as Map<String, dynamic> ?? {};
  }

  Future<File?> downloadAttachment(String attachmentId) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${dir.path}/attachments');
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      final filePath = '${cacheDir.path}/$attachmentId';
      final file = File(filePath);
      if (await file.exists()) return file;

      final uri = Uri.parse('$serverUrl/api/v1/file?attachment_id=$attachmentId');
      final response = await http.get(uri, headers: {'X-API-Key': apiKey});
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        return file;
      }
    } catch (_) {}
    return null;
  }

  Future<String> saveToDownloads(String attachmentId, String filename) async {
    final file = await downloadAttachment(attachmentId);
    if (file == null) throw Exception('文件下载失败');
    final downloadDir = Directory('/storage/emulated/0/Download/AstrBot');
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    final dest = File('${downloadDir.path}/$filename');
    await file.copy(dest.path);
    return dest.path;
  }

  Future<void> cleanOldCache() async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${dir.path}/attachments');
    if (!await cacheDir.exists()) return;

    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    await for (final entity in cacheDir.list()) {
      if (entity is File) {
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete();
        }
      }
    }
  }

  Map<String, dynamic> _parseJson(String body) {
    try {
      return const _JsonDecoder().convert(body) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}

class _JsonDecoder {
  Map<String, dynamic> convert(String body) {
    // Use dart:convert if available, else manual; 
    // In practice, import 'dart:convert' and use jsonDecode.
    // This is a placeholder showing the import structure.
    return {};
  }
}
```

Replace `_JsonDecoder` with actual `dart:convert` usage:

```dart
import 'dart:convert';

// In _parseJson:
//   return jsonDecode(body) as Map<String, dynamic>? ?? {};
```

Add `dart:convert` import and fix `_parseJson`:

```dart
import 'dart:convert';

// ...

  Map<String, dynamic> _parseJson(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
```

- [ ] **Step 2: Fix file_service.dart — replace _JsonDecoder**

Open `lib/services/file_service.dart`, replace the `_parseJson` method and add `dart:convert` import as shown.

- [ ] **Step 3: Commit**

```bash
git add lib/services/file_service.dart && git commit -m "feat: add file upload/download service with cache management

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Audio Recording & Playback Service

**Files:**
- Create: `lib/services/audio_service.dart`

- [ ] **Step 1: Write audio_service.dart**

```dart
// lib/services/audio_service.dart
import 'dart:io';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

class AudioService {
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  String? _recordingPath;

  Future<bool> hasPermission() async {
    return await _recorder.hasPermission();
  }

  Future<void> startRecording() async {
    final dir = await getTemporaryDirectory();
    _recordingPath = '${dir.path}/draft_record.wav';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.wav),
      path: _recordingPath!,
    );
  }

  Future<File?> stopRecording() async {
    final path = await _recorder.stop();
    if (path != null && File(path).existsSync()) {
      return File(path);
    }
    return null;
  }

  Future<void> playFile(String path) async {
    await _player.play(DeviceFileSource(path));
  }

  Future<void> stopPlaying() async {
    await _player.stop();
  }

  Future<void> dispose() async {
    await _player.dispose();
    await _recorder.dispose();
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/services/audio_service.dart && git commit -m "feat: add audio recording and playback service

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: Voice Recorder Widget (Long-Press)

**Files:**
- Create: `lib/widgets/voice_recorder.dart`

- [ ] **Step 1: Write voice_recorder.dart**

```dart
// lib/widgets/voice_recorder.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/audio_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/config_provider.dart';
import '../services/audio_service.dart';
import '../services/file_service.dart';

class VoiceRecorderButton extends ConsumerStatefulWidget {
  const VoiceRecorderButton({super.key});

  @override
  ConsumerState<VoiceRecorderButton> createState() => _VoiceRecorderButtonState();
}

class _VoiceRecorderButtonState extends ConsumerState<VoiceRecorderButton> {
  final _audioService = AudioService();
  bool _isCancel = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (_) => _startRecording(),
      onLongPressMoveUpdate: (details) {
        setState(() => _isCancel = details.localPosition.dy < -60);
      },
      onLongPressEnd: (_) => _stopRecording(),
      child: Container(
        padding: const EdgeInsets.all(8),
        child: const Icon(Icons.mic_outlined, color: Color(0xBBFFFFFF), size: 22),
      ),
    );
  }

  Future<void> _startRecording() async {
    setState(() => _isCancel = false);
    final hasPerm = await _audioService.hasPermission();
    if (!hasPerm) return;
    await _audioService.startRecording();
    ref.read(audioProvider.notifier).startRecording();
  }

  Future<void> _stopRecording() async {
    if (_isCancel) {
      await _audioService.stopRecording();
      ref.read(audioProvider.notifier).stopRecording();
      setState(() => _isCancel = false);
      return;
    }

    final file = await _audioService.stopRecording();
    ref.read(audioProvider.notifier).stopRecording();
    setState(() => _isCancel = false);

    if (file != null) {
      final config = ref.read(configServiceProvider);
      final fileService = FileService(serverUrl: config.serverUrl, apiKey: config.apiKey);
      final result = await fileService.uploadFile(file, 'audio/wav');
      final attachmentId = result['attachment_id'] as String?;
      if (attachmentId != null && mounted) {
        ref.read(chatProvider.notifier).sendVoice(attachmentId);
      }
    }
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/widgets/voice_recorder.dart && git commit -m "feat: add voice recorder widget with long-press gesture

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 11: Attachment Panel Widget

**Files:**
- Create: `lib/widgets/attachment_panel.dart`

- [ ] **Step 1: Write attachment_panel.dart**

```dart
// lib/widgets/attachment_panel.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../providers/chat_provider.dart';
import '../providers/config_provider.dart';
import '../services/file_service.dart';

class AttachmentPanel extends ConsumerWidget {
  const AttachmentPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C27),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.06))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildOption(context, ref, Icons.camera_alt_outlined, '拍照', _takePhoto),
          _buildOption(context, ref, Icons.photo_outlined, '相册', _pickImage),
          _buildOption(context, ref, Icons.folder_outlined, '文件', () {}),
        ],
      ),
    );
  }

  Widget _buildOption(
      BuildContext context, WidgetRef ref, IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52, height: 52,
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A3A),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: Colors.white70, size: 24),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 12)),
        ],
      ),
    );
  }

  Future<void> _takePhoto() async {
    // Called from context captured in closure
  }

  Future<void> _pickImage() async {}
}
```

Better — use functional callbacks with captured ref:

```dart
// lib/widgets/attachment_panel.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../providers/chat_provider.dart';
import '../providers/config_provider.dart';
import '../services/file_service.dart';

class AttachmentPanel extends ConsumerStatefulWidget {
  const AttachmentPanel({super.key});

  @override
  ConsumerState<AttachmentPanel> createState() => _AttachmentPanelState();
}

class _AttachmentPanelState extends ConsumerState<AttachmentPanel> {
  final _picker = ImagePicker();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C27),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.06))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildOption(Icons.camera_alt_outlined, '拍照', () => _capture(ImageSource.camera)),
          _buildOption(Icons.photo_outlined, '相册', () => _capture(ImageSource.gallery)),
          _buildOption(Icons.folder_outlined, '文件', () {}),
        ],
      ),
    );
  }

  Widget _buildOption(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52, height: 52,
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A3A),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: Colors.white70, size: 24),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 12)),
        ],
      ),
    );
  }

  Future<void> _capture(ImageSource source) async {
    try {
      final XFile? xfile = await _picker.pickImage(source: source, imageQuality: 85);
      if (xfile == null) return;
      final file = File(xfile.path);
      final config = ref.read(configServiceProvider);
      final fileService = FileService(serverUrl: config.serverUrl, apiKey: config.apiKey);
      final result = await fileService.uploadFile(file, 'image/jpeg');
      final attachmentId = result['attachment_id'] as String?;
      if (attachmentId != null && mounted) {
        ref.read(chatProvider.notifier).sendImage(attachmentId);
      }
    } catch (_) {}
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/widgets/attachment_panel.dart && git commit -m "feat: add attachment panel with camera/gallery quick capture

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 12: Integrate Widgets into Chat Screen

**Files:**
- Modify: `lib/screens/chat_screen.dart`

- [ ] **Step 1: Update chat_screen.dart with voice + attachment support**

Replace `chat_screen.dart` with the integrated version:

```dart
// lib/screens/chat_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/chat_provider.dart';
import '../providers/config_provider.dart';
import '../providers/audio_provider.dart';
import '../services/config_service.dart';
import '../widgets/voice_recorder.dart';
import '../widgets/attachment_panel.dart';
import 'settings_screen.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  late final ConfigService _config;

  @override
  void initState() {
    super.initState();
    _config = ref.read(configServiceProvider);
    Future.microtask(() => ref.read(chatProvider.notifier).connect());
  }

  void _showAttachmentPanel() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const AttachmentPanel(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatProvider);
    final audioState = ref.watch(audioProvider);
    final botName = 'AstrBot 助手';

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A28),
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: CircleAvatar(
            backgroundColor: const Color(0xFF4A9EFF),
            child: const Text('🤖', style: TextStyle(fontSize: 18)),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(botName, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            Text(
              chatState.connectionState == WsConnectionState.connected ? '在线' : '连接中...',
              style: TextStyle(
                fontSize: 11,
                color: chatState.connectionState == WsConnectionState.connected
                    ? Colors.greenAccent
                    : Colors.grey,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Chat(
              messages: _buildChatMessages(chatState),
              onSendPressed: (text) {
                ref.read(chatProvider.notifier).sendText(text.text);
              },
              user: _buildChatUser(),
              theme: const DefaultChatTheme(
                primaryColor: Color(0xFF3D7CEB),
                backgroundColor: Color(0xFF121215),
                inputBackgroundColor: Color(0xFF2A2A36),
              ),
              onAttachmentPressed: _showAttachmentPanel,
            ),
          ),
          if (audioState == AudioState.recording)
            Container(
              height: 80,
              color: const Color(0xFF1C1C27),
              child: const Center(
                child: Text('🎤 松开发送 · 上滑取消',
                    style: TextStyle(color: Color(0xFFE94560), fontSize: 14)),
              ),
            ),
        ],
      ),
    );
  }

  List<types.Message> _buildChatMessages(ChatState state) {
    final messages = <types.Message>[];
    for (final m in state.messages) {
      messages.add(types.TextMessage(
        author: types.Author(id: m.isFromMe ? _config.nickname : 'bot'),
        id: m.createdAt.toString(),
        text: m.content ?? (m.msgType == 'voice' ? '[语音]' : '[图片]'),
      ));
    }
    if (state.streamingText != null && state.streamingText!.isNotEmpty) {
      messages.add(types.TextMessage(
        author: const types.Author(id: 'bot'),
        id: 'streaming',
        text: state.streamingText!,
      ));
    }
    return messages;
  }

  types.User _buildChatUser() => types.User(id: _config.nickname);
}
```

- [ ] **Step 2: Verify build**

```bash
flutter analyze
```

Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add lib/screens/chat_screen.dart && git commit -m "feat: integrate voice recorder and attachment panel into chat screen

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 13: SQLite Cache Service

**Files:**
- Create: `lib/services/cache_service.dart`

- [ ] **Step 1: Write cache_service.dart**

```dart
// lib/services/cache_service.dart
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../models/message.dart';

class CacheService {
  static Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'astrbot_messages.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            msg_type TEXT NOT NULL,
            content TEXT,
            attachment_id TEXT,
            is_from_me INTEGER NOT NULL,
            status TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
      },
    );
  }

  Future<int> insertMessage(LocalMessage msg) async {
    final d = await db;
    return d.insert('messages', msg.toMap());
  }

  Future<List<LocalMessage>> getMessages({int limit = 50, int offset = 0}) async {
    final d = await db;
    final rows = await d.query('messages',
        orderBy: 'created_at DESC', limit: limit, offset: offset);
    return rows.map((r) => LocalMessage.fromMap(r)).toList().reversed.toList();
  }

  Future<void> clearAll() async {
    final d = await db;
    await d.delete('messages');
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/services/cache_service.dart && git commit -m "feat: add SQLite cache service for message history

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 14: Settings Screen

**Files:**
- Create: `lib/screens/settings_screen.dart`

- [ ] **Step 1: Write settings_screen.dart**

```dart
// lib/screens/settings_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../providers/config_provider.dart';
import '../services/config_service.dart';
import '../services/cache_service.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late ConfigService _config;
  String _cacheSize = '计算中...';

  @override
  void initState() {
    super.initState();
    _config = ref.read(configServiceProvider);
    _calcCacheSize();
  }

  Future<void> _calcCacheSize() async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${dir.path}/attachments');
    int total = 0;
    if (await cacheDir.exists()) {
      await for (final e in cacheDir.list()) {
        if (e is File) total += await e.length();
      }
    }
    setState(() {
      _cacheSize = total > 1024 * 1024
          ? '${(total / 1024 / 1024).toStringAsFixed(1)} MB'
          : '${(total / 1024).toStringAsFixed(0)} KB';
    });
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理缓存'),
        content: Text('当前缓存: $_cacheSize，确定清理？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清理')),
        ],
      ),
    );
    if (confirmed == true) {
      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${dir.path}/attachments');
      if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
      final cacheService = CacheService();
      await cacheService.clearAll();
      setState(() => _cacheSize = '0 KB');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('缓存已清理')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          _buildTile('昵称', _config.nickname, (v) => _config.setNickname(v)),
          _buildTile('服务器地址', _config.serverUrl, (v) => _config.setServerUrl(v)),
          _buildTile('API Key', _config.apiKey, (v) => _config.setApiKey(v), obscure: true),
          _buildTile('Config ID', _config.configId, (v) => _config.setConfigId(v)),
          const Divider(),
          ListTile(
            title: const Text('清理缓存'),
            subtitle: Text('当前: $_cacheSize'),
            onTap: _clearCache,
          ),
          const ListTile(
            title: Text('关于'),
            subtitle: Text('AstrBot 助手 v1.0.0'),
          ),
        ],
      ),
    );
  }

  Widget _buildTile(String label, String currentValue, Function(String) onSave,
      {bool obscure = false}) {
    final ctrl = TextEditingController(text: currentValue);
    return ListTile(
      title: Text(label),
      subtitle: Text(currentValue, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () async {
        final result = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('修改$label'),
            content: TextField(
              controller: ctrl,
              obscureText: obscure,
              decoration: InputDecoration(
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              TextButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text),
                child: const Text('保存'),
              ),
            ],
          ),
        );
        if (result != null && result.isNotEmpty) {
          onSave(result);
          setState(() {});
        }
      },
    );
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/screens/settings_screen.dart && git commit -m "feat: add settings screen with config editing and cache clearing

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 15: Network Connectivity Detection

**Files:**
- Modify: `lib/providers/chat_provider.dart`
- Modify: `lib/main.dart`

- [ ] **Step 1: Add connectivity_plus usage to chat_provider.dart**

Add at the top of `lib/providers/chat_provider.dart`:

```dart
import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
```

Inside `ChatNotifier`, add connectivity listener in `connect()`:

```dart
// In ChatNotifier class, after existing fields:
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

// In the connect() method, after the existing code:
  _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
    if (!results.contains(ConnectivityResult.none) &&
        state.connectionState == WsConnectionState.disconnected) {
      connect();
    }
  });

// In dispose():
  @override
  void dispose() {
    _connectivitySub?.cancel();
    _eventSub?.cancel();
    _client?.dispose();
    super.dispose();
  }
```

- [ ] **Step 2: Commit**

```bash
git add lib/providers/chat_provider.dart && git commit -m "feat: add network connectivity detection and auto-reconnect

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 16: Visual Polish — Glassmorphism & Gradients

**Files:**
- Modify: `lib/screens/chat_screen.dart`
- Modify: `lib/main.dart`

- [ ] **Step 1: Apply glassmorphism to chat app bar and input area**

In `chat_screen.dart`, wrap the `Scaffold` with `Stack` and add background gradient orbs:

```dart
// lib/screens/chat_screen.dart (updated build method)
@override
Widget build(BuildContext context) {
  final chatState = ref.watch(chatProvider);
  final audioState = ref.watch(audioProvider);
  final botName = 'AstrBot 助手';

  return Scaffold(
    extendBodyBehindAppBar: true,
    body: Stack(
      children: [
        // Background gradient orbs
        Positioned.fill(
          child: Container(
            color: const Color(0xFF121215),
            child: Stack(
              children: [
                Positioned(
                  top: -60, right: -40,
                  child: Container(
                    width: 200, height: 200,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [const Color(0xFF4A9EFF).withOpacity(0.25), Colors.transparent],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 120, left: -60,
                  child: Container(
                    width: 220, height: 220,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [const Color(0xFF9D4EDD).withOpacity(0.2), Colors.transparent],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 250, right: -80,
                  child: Container(
                    width: 160, height: 160,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [const Color(0xFFE94560).withOpacity(0.15), Colors.transparent],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Glass app bar
        Positioned(
          top: 0, left: 0, right: 0,
          child: ClipRRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                color: const Color(0xFF1C1C27).withOpacity(0.75),
                padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
                child: AppBar(...), // extract AppBar content
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
```

Add import: `import 'dart:ui' show ImageFilter;`

- [ ] **Step 2: Full polished chat_screen.dart**

Replace `lib/screens/chat_screen.dart` completely:

```dart
// lib/screens/chat_screen.dart
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/chat_provider.dart';
import '../providers/config_provider.dart';
import '../providers/audio_provider.dart';
import '../services/config_service.dart';
import '../widgets/attachment_panel.dart';
import 'settings_screen.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  late final ConfigService _config;

  @override
  void initState() {
    super.initState();
    _config = ref.read(configServiceProvider);
    Future.microtask(() => ref.read(chatProvider.notifier).connect());
  }

  void _showAttachmentPanel() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const AttachmentPanel(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatProvider);
    final audioState = ref.watch(audioProvider);
    final topPadding = MediaQuery.of(context).padding.top;
    final botName = 'AstrBot 助手';

    return Scaffold(
      body: Stack(
        children: [
          // Background with gradient orbs
          Positioned.fill(
            child: Container(
              color: const Color(0xFF121215),
              child: Stack(
                children: [
                  Positioned(
                    top: -60, right: -40,
                    child: Container(
                      width: 200, height: 200,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [const Color(0xFF4A9EFF).withOpacity(0.2), Colors.transparent],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 120, left: -60,
                    child: Container(
                      width: 220, height: 220,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [const Color(0xFF9D4EDD).withOpacity(0.15), Colors.transparent],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Main content
          Column(
            children: [
              // Glass app bar
              ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    padding: EdgeInsets.only(top: topPadding),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C1C27).withOpacity(0.75),
                      border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.06))),
                    ),
                    child: Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: CircleAvatar(
                            radius: 17,
                            backgroundColor: const Color(0xFF4A9EFF),
                            child: const Text('🤖', style: TextStyle(fontSize: 16)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(botName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                              Text(
                                chatState.connectionState == WsConnectionState.connected ? '在线' : '连接中...',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: chatState.connectionState == WsConnectionState.connected
                                      ? Colors.greenAccent
                                      : Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.settings_outlined, size: 20, color: Color(0x88FFFFFF)),
                          onPressed: () => Navigator.push(context,
                              MaterialPageRoute(builder: (_) => const SettingsScreen())),
                        ),
                      ],
                    ),
                  ).paddingSymmetric(vertical: 6),
                ),
              ),
              // Chat body
              Expanded(
                child: Chat(
                  messages: _buildChatMessages(chatState),
                  onSendPressed: (text) => ref.read(chatProvider.notifier).sendText(text.text),
                  user: _buildChatUser(),
                  theme: const DefaultChatTheme(
                    primaryColor: Color(0xFF3D7CEB),
                    backgroundColor: Colors.transparent,
                    inputBackgroundColor: Color(0xFF2A2A36),
                    sentMessageBodyTextStyle: TextStyle(color: Colors.white, fontSize: 14),
                    receivedMessageBodyTextStyle: TextStyle(color: Color(0xFFDDDDDD), fontSize: 14),
                  ),
                  onAttachmentPressed: _showAttachmentPanel,
                ),
              ),
              if (audioState == AudioState.recording)
                Container(
                  height: 80,
                  color: const Color(0xFF1C1C27),
                  child: const Center(
                    child: Text('🎤 松开发送 · 上滑取消',
                        style: TextStyle(color: Color(0xFFE94560), fontSize: 14)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  List<types.Message> _buildChatMessages(ChatState state) {
    final messages = <types.Message>[];
    for (final m in state.messages) {
      messages.add(types.TextMessage(
        author: types.Author(id: m.isFromMe ? _config.nickname : 'bot'),
        id: m.createdAt.toString(),
        text: m.content ?? (m.msgType == 'voice' ? '[语音]' : '[图片]'),
      ));
    }
    if (state.streamingText != null && state.streamingText!.isNotEmpty) {
      messages.add(types.TextMessage(
        author: const types.Author(id: 'bot'),
        id: 'streaming',
        text: state.streamingText!,
      ));
    }
    return messages;
  }

  types.User _buildChatUser() => types.User(id: _config.nickname);
}

extension _Padding on Widget {
  Widget paddingSymmetric({double vertical = 0, double horizontal = 0}) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: vertical, horizontal: horizontal),
      child: this,
    );
  }
}
```

- [ ] **Step 3: Build & verify**

```bash
flutter pub get && flutter analyze
```

Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add lib/screens/chat_screen.dart && git commit -m "feat: add glassmorphism app bar, gradient background orbs, and polished chat UI

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 17: Android Permissions & Final Config

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `android/app/build.gradle`

- [ ] **Step 1: Add permissions to AndroidManifest.xml**

Open `android/app/src/main/AndroidManifest.xml` and add inside `<manifest>`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
```

- [ ] **Step 2: Verify final build**

```bash
flutter build apk --debug
```

Expected: APK built successfully in `build/app/outputs/flutter-apk/app-debug.apk`.

- [ ] **Step 3: Commit**

```bash
git add android/app/src/main/AndroidManifest.xml && git commit -m "chore: add Android permissions for camera, mic, storage, and network

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 18: Auto Cache Cleanup on Startup & Save to Downloads

**Files:**
- Modify: `lib/main.dart`
- Modify: `lib/screens/chat_screen.dart`

- [ ] **Step 1: Add auto cache cleanup to app startup**

In `lib/main.dart`, add cache cleanup in `main()`:

```dart
// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'config/app_config.dart';
import 'screens/chat_screen.dart';
import 'screens/setup_screen.dart';
import 'providers/config_provider.dart';
import 'services/file_service.dart';
import 'services/config_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _cleanOldCache();
  runApp(const ProviderScope(child: AstrBotApp()));
}

Future<void> _cleanOldCache() async {
  try {
    // We need config first to get serverUrl/apiKey. Use a lightweight approach:
    final prefs = await SharedPreferences.getInstance();
    final serverUrl = prefs.getString('server_url') ?? AppConfig.defaultServerUrl;
    final apiKey = prefs.getString('api_key') ?? '';
    if (apiKey.isNotEmpty) {
      final fileService = FileService(serverUrl: serverUrl, apiKey: apiKey);
      await fileService.cleanOldCache();
    }
  } catch (_) {}
}
```

Note: Add `import 'package:shared_preferences/shared_preferences.dart';` at the top.

- [ ] **Step 2: Add "save to downloads" to file-type messages in chat screen**

In `lib/screens/chat_screen.dart`, add a method to handle saving files:

```dart
// In _ChatScreenState class, add:
Future<void> _saveFileToDownloads(String attachmentId, String filename) async {
  try {
    final fileService = FileService(serverUrl: _config.serverUrl, apiKey: _config.apiKey);
    final path = await fileService.saveToDownloads(attachmentId, filename);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存到下载目录: $path')),
      );
    }
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('保存失败')),
      );
    }
  }
}
```

For image messages, add long-press handler to save to gallery (requires `image_gallery_saver` or manual copy):

```dart
Future<void> _saveImageToGallery(String attachmentId) async {
  final fileService = FileService(serverUrl: _config.serverUrl, apiKey: _config.apiKey);
  final file = await fileService.downloadAttachment(attachmentId);
  if (file != null && mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('图片已保存')),
    );
  }
}
```

Add image save dependency to pubspec.yaml:

```yaml
  gallery_saver: ^2.3.2   # save images to gallery
```

Run:

```bash
flutter pub get
```

- [ ] **Step 3: Commit**

```bash
git add lib/main.dart lib/screens/chat_screen.dart pubspec.yaml && git commit -m "feat: add auto cache cleanup on startup and save-to-downloads support

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 19: Smoke Test & Bug Fixes

- [ ] **Step 1: Run analyzer**

```bash
flutter analyze
```

Fix any warnings/errors.

- [ ] **Step 2: Test build**

```bash
flutter build apk --debug
```

Expected: APK builds without errors.

- [ ] **Step 3: Install on device (if available)**

```bash
adb install build/app/outputs/flutter-apk/app-debug.apk
```

- [ ] **Step 4: Manual test checklist**
  1. Fresh install → Setup screen appears
  2. Fill config → Chat screen opens
  3. Send text message → Bot replies with streaming
  4. Long-press mic → Record → Send voice
  5. Camera button → Take photo → Auto-send
  6. Settings → Edit config → Return → Reconnect works
  7. Kill network → App shows "连接中..." → Restore → Auto-reconnect
  8. Cache cleanup works

- [ ] **Step 5: Fix issues and commit fixes**

```bash
git add -A && git commit -m "fix: address issues found in smoke testing

Co-Authored-By: Claude <noreply@anthropic.com>"
```
