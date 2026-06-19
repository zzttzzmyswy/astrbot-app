// lib/screens/settings_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../main.dart';
import '../providers/config_provider.dart';
import '../services/config_service.dart';
import '../providers/chat_provider.dart';
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
    if (mounted) {
      setState(() {
        _cacheSize = total > 1024 * 1024
            ? '${(total / 1024 / 1024).toStringAsFixed(1)} MB'
            : '${(total / 1024).toStringAsFixed(0)} KB';
      });
    }
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
      if (mounted) {
        setState(() => _cacheSize = '0 KB');
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
          Consumer(builder: (context, ref, _) {
            final currentMode = ref.watch(themeModeProvider);
            return ListTile(
              title: const Text('主题模式'),
              subtitle: Text(currentMode == ThemeMode.light ? '白天' : currentMode == ThemeMode.dark ? '夜间' : '跟随系统'),
              trailing: DropdownButton<ThemeMode>(
                value: currentMode,
                underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(value: ThemeMode.system, child: Text('自动')),
                  DropdownMenuItem(value: ThemeMode.light, child: Text('白天')),
                  DropdownMenuItem(value: ThemeMode.dark, child: Text('夜间')),
                ],
                onChanged: (v) async {
                  if (v != null) {
                    await _config.setThemeMode(v);
                    ref.read(themeModeProvider.notifier).state = v;
                  }
                },
              ),
            );
          }),
          ListTile(
            title: const Text('连接模式'),
            subtitle: Text(_config.connectionMode == 'sse' ? 'SSE（默认，更稳定）' : 'WebSocket'),
            trailing: DropdownButton<String>(
              value: _config.connectionMode,
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 'sse', child: Text('SSE（推荐）')),
                DropdownMenuItem(value: 'ws', child: Text('WebSocket')),
              ],
              onChanged: (v) async {
                if (v != null) {
                  await _config.setConnectionMode(v);
                  setState(() {});
                  // Reconnect with new mode
                  ref.read(chatProvider.notifier).connect();
                }
              },
            ),
          ),
          const Divider(),
          ListTile(
            title: const Text('清理缓存'),
            subtitle: Text('当前: $_cacheSize'),
            onTap: _clearCache,
          ),
          const ListTile(
            title: Text('关于'),
            subtitle: Text('Bot助手 v1.0.0'),
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
