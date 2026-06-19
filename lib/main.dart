import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'services/config_service.dart';
import 'services/file_service.dart';
import 'services/foreground_service.dart';
import 'config/app_config.dart';
import 'screens/chat_screen.dart';
import 'screens/setup_screen.dart';
import 'providers/config_provider.dart';

final themeModeProvider = StateProvider<ThemeMode>((ref) {
  return ref.read(configServiceProvider).themeMode;
});

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize the foreground service (keeps the app alive in background so
  // the chat connection is not dropped and no messages are lost).
  initKeepAliveService();
  // Pre-init SharedPreferences so theme can be read immediately
  final config = ConfigService();
  await config.init();
  runApp(ProviderScope(overrides: [
    configServiceProvider.overrideWithValue(config),
  ], child: const AstrBotApp()));
  // 非阻塞清理过期附件磁盘缓存(>7 天)。失败不影响启动。
  Future.microtask(() async {
    try {
      final cleaner = ConfigService();
      await cleaner.init();
      await FileService(serverUrl: cleaner.serverUrl, apiKey: cleaner.apiKey)
          .cleanOldCache();
    } catch (_) {}
  });
}

class AstrBotApp extends ConsumerWidget {
  const AstrBotApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncConfig = ref.watch(configInitializedProvider);
    final themeMode = ref.watch(themeModeProvider);

    ErrorWidget.builder = (details) => Container(color: const Color(0xFF1A1A2E),
      child: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(24),
        child: SelectableText('${details.exception}', style: const TextStyle(color: Colors.redAccent, fontSize: 14, fontFamily: 'monospace')))));

    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light().copyWith(
        scaffoldBackgroundColor: const Color(0xFFEDEDED),
        cardColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1676F2), brightness: Brightness.light).copyWith(surface: const Color(0xFFEDEDED)),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.white, foregroundColor: Color(0xFF101010), elevation: 0.5),
      ),
      darkTheme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121215),
        cardColor: const Color(0xFF1C1C1E),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A9EFF), brightness: Brightness.dark).copyWith(surface: const Color(0xFF121215)),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF1C1C1E), foregroundColor: Colors.white, elevation: 0.5),
      ),
      themeMode: themeMode,
      home: asyncConfig.when(
        data: (isConfigured) => isConfigured ? const ChatScreen() : const SetupScreen(),
        loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
        error: (_, __) => const SetupScreen(),
      ),
    );
  }
}
