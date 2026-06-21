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
import '../services/update_service.dart';
import '../services/apk_installer.dart';
import '../services/device_oem_service.dart';
import '../util/key_mask.dart';
import '../util/oem_whitelist.dart';
import '../widgets/oem_whitelist_dialog.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late ConfigService _config;
  String _cacheSize = '计算中...';
  String _currentVersion = '';
  // 后台运行引导(荣耀/华为等国产机型)。检测到需要时在设置页展示一个入口,
  // 点击弹出步骤引导(不再在启动/后台断连时自动弹窗打扰用户)。
  OemWhitelistGuide? _oemGuide;

  @override
  void initState() {
    super.initState();
    _config = ref.read(configServiceProvider);
    _calcCacheSize();
    UpdateService().currentVersion().then((v) {
      if (mounted) setState(() => _currentVersion = v);
    });
    _loadOemGuide();
  }

  Future<void> _loadOemGuide() async {
    final info = await const DeviceOemService().getInfo();
    if (!mounted) return;
    final guide = whitelistGuideFor(info);
    if (guide.needsGuide) {
      setState(() => _oemGuide = guide);
    }
  }

  void _showOemGuide() {
    final guide = _oemGuide;
    if (guide == null || !guide.needsGuide) return;
    showDialog<void>(
      context: context,
      builder: (_) => OemWhitelistDialog(guide: guide),
    );
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
          _ApiKeyTile(config: _config, onChanged: () => setState(() {})),
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
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_config.connectionMode == 'sse'
                    ? 'SSE（默认，更稳定）'
                    : 'WebSocket'),
                const SizedBox(height: 2),
                const Text(
                  'SSE:仅前台(本 app 聚焦时)接收消息。\n'
                  'WS:可后台接收,但网络波动断连可能致 AstrBot 当前会话卡死、'
                  '无法再收消息,届时需重启 AstrBot。',
                  style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.35),
                ),
              ],
            ),
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
          if (_oemGuide != null && _oemGuide!.needsGuide)
            ListTile(
              leading: Icon(Icons.bolt_rounded,
                  color: Theme.of(context).colorScheme.primary, size: 22),
              title: const Text('后台运行设置'),
              subtitle: Text(_oemGuide!.reason, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, height: 1.3)),
              trailing: const Icon(Icons.chevron_right_rounded, size: 20),
              onTap: _showOemGuide,
            ),
          const Divider(),
          ListTile(
            title: const Text('清理缓存'),
            subtitle: Text('当前: $_cacheSize'),
            onTap: _clearCache,
          ),
          ListTile(
            title: const Text('关于'),
            subtitle: Text(_currentVersion.isEmpty
                ? '检查更新'
                : 'Bot助手 v$_currentVersion · 点击检查更新'),
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) => const _UpdateDialog(),
            ),
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

/// API Key 专用 tile:默认只显示前 10 个字符(掩码),眼睛按钮切换明文/掩码;
/// 点 tile 进编辑对话框(对话框内同样可切换显隐)。
class _ApiKeyTile extends StatefulWidget {
  final ConfigService config;
  final VoidCallback onChanged;
  const _ApiKeyTile({required this.config, required this.onChanged});
  @override State<_ApiKeyTile> createState() => _ApiKeyTileState();
}

class _ApiKeyTileState extends State<_ApiKeyTile> {
  bool _revealed = false;

  Future<void> _edit() async {
    final ctrl = TextEditingController(text: widget.config.apiKey);
    bool dialogRevealed = false;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setS) {
          return AlertDialog(
            title: const Text('修改 API Key'),
            content: TextField(
              controller: ctrl,
              obscureText: !dialogRevealed,
              decoration: InputDecoration(
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                suffixIcon: IconButton(
                  icon: Icon(dialogRevealed ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                      size: 20),
                  onPressed: () => setS(() => dialogRevealed = !dialogRevealed),
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              TextButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text),
                child: const Text('保存'),
              ),
            ],
          );
        });
      },
    );
    if (result != null && result.isNotEmpty) {
      await widget.config.setApiKey(result);
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final key = widget.config.apiKey;
    final shown = key.isEmpty ? '未设置' : (_revealed ? key : maskKey(key));
    return ListTile(
      title: const Text('API Key'),
      subtitle: Text(shown, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontFamily: key.isEmpty ? null : 'monospace')),
      trailing: IconButton(
        icon: Icon(_revealed ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
        tooltip: _revealed ? '隐藏' : '显示',
        onPressed: () => setState(() => _revealed = !_revealed),
      ),
      onTap: _edit,
    );
  }
}

/// 检查更新对话框:检查 → 发现新版本/已是最新/失败 → 下载(进度) → 触发安装。
class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog();
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  final UpdateService _svc = UpdateService();
  _S _s = _S.checking;
  UpdateCheck? _check;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _doCheck();
  }

  Future<void> _doCheck() async {
    setState(() => _s = _S.checking);
    final c = await _svc.check();
    if (!mounted) return;
    _check = c;
    setState(() {
      if (c.error != null) {
        _s = _S.error;
      } else if (c.hasUpdate) {
        _s = _S.available;
      } else {
        _s = _S.latest;
      }
    });
  }

  Future<void> _downloadAndInstall() async {
    final info = _check?.latest;
    if (info == null) return;
    setState(() { _s = _S.downloading; _progress = 0; });
    try {
      final path = await _svc.download(info.apkUrl, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() => _s = _S.installing);
      await ApkInstaller.install(path);
      // 系统安装器已弹出;不自动关对话框,用户可自行返回。
    } catch (e) {
      if (mounted) {
        _check = UpdateCheck(currentVersion: _check?.currentVersion ?? '', error: '更新失败: $e');
        setState(() => _s = _S.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _check?.latest;
    final title = switch (_s) {
      _S.checking => '检查更新',
      _S.available => '发现新版本 ${info?.tag ?? ''}',
      _S.latest => '已是最新版本',
      _S.error => '检查更新',
      _S.downloading => '正在下载',
      _S.installing => '正在安装',
    };
    final actions = <Widget>[
      if (_s == _S.error)
        TextButton(onPressed: _doCheck, child: const Text('重试')),
      if (_s == _S.available) ...[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('以后再说')),
        FilledButton(onPressed: _downloadAndInstall, child: const Text('立即更新')),
      ],
      if (_s == _S.latest || _s == _S.error)
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
    ];
    return AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: _content(info),
      ),
      actions: actions,
    );
  }

  Widget _content(UpdateInfo? info) {
    switch (_s) {
      case _S.checking:
        return const Row(children: [
          SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 16),
          Text('正在检查最新版本...'),
        ]);
      case _S.available:
        final notes = (info?.notes.trim().isNotEmpty == true) ? info!.notes.trim() : '修复与改进。';
        return SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (info!.sizeLabel.isNotEmpty)
              Padding(padding: const EdgeInsets.only(bottom: 8),
                child: Text('大小:${info.sizeLabel}  当前:v${_check!.currentVersion}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey))),
            Text(notes, style: const TextStyle(fontSize: 13, height: 1.4)),
          ]),
        );
      case _S.latest:
        return Text('当前已是最新版本 v${_check?.currentVersion ?? ""}。');
      case _S.error:
        return Text(_check?.error ?? '检查失败,请稍后重试。');
      case _S.downloading:
        final pct = (_progress * 100).round();
        return Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(value: _progress > 0 ? _progress : null),
          const SizedBox(height: 10),
          Text('$pct%', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ]);
      case _S.installing:
        return const Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(height: 12),
          Text('下载完成,请在系统弹出的安装界面确认安装。', style: TextStyle(fontSize: 13, height: 1.4)),
        ]);
    }
  }
}

enum _S { checking, available, latest, error, downloading, installing }