// lib/screens/settings_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../main.dart';
import '../providers/config_provider.dart';
import '../services/config_service.dart';
import '../services/cache_service.dart';
import '../services/update_service.dart';
import '../services/apk_installer.dart';
import '../services/device_oem_service.dart';
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
    if (guide.needsGuide) setState(() => _oemGuide = guide);
  }

  void _showOemGuide() {
    final guide = _oemGuide;
    if (guide == null || !guide.needsGuide) return;
    showDialog<void>(
        context: context, builder: (_) => OemWhitelistDialog(guide: guide));
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
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清理')),
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
          Consumer(builder: (context, ref, _) {
            final currentMode = ref.watch(themeModeProvider);
            return ListTile(
              title: const Text('主题模式'),
              subtitle: Text(currentMode == ThemeMode.light
                  ? '白天'
                  : currentMode == ThemeMode.dark
                      ? '夜间'
                      : '跟随系统'),
              trailing: DropdownButton<ThemeMode>(
                value: currentMode,
                underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(
                      value: ThemeMode.system, child: Text('自动')),
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
          if (_oemGuide != null && _oemGuide!.needsGuide)
            ListTile(
              leading: Icon(Icons.bolt_rounded,
                  color: Theme.of(context).colorScheme.primary, size: 22),
              title: const Text('后台运行设置'),
              subtitle: Text(_oemGuide!.reason,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
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
                context: context, builder: (_) => const _UpdateDialog()),
          ),
        ],
      ),
    );
  }
}

/// 检查更新对话框（沿用既有实现）。
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
    setState(() {
      _s = _S.downloading;
      _progress = 0;
    });
    try {
      final path = await _svc.download(info.apkUrl, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() => _s = _S.installing);
      await ApkInstaller.install(path);
    } catch (e) {
      if (mounted) {
        _check = UpdateCheck(
            currentVersion: _check?.currentVersion ?? '',
            error: '更新失败: $e');
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
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('以后再说')),
        FilledButton(
            onPressed: _downloadAndInstall, child: const Text('立即更新')),
      ],
      if (_s == _S.latest || _s == _S.error)
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('关闭')),
    ];
    return AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320), child: _content(info)),
      actions: actions,
    );
  }

  Widget _content(UpdateInfo? info) {
    switch (_s) {
      case _S.checking:
        return const Row(children: [
          SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 16),
          Text('正在检查最新版本...'),
        ]);
      case _S.available:
        final notes = (info?.notes.trim().isNotEmpty == true)
            ? info!.notes.trim()
            : '修复与改进。';
        return SingleChildScrollView(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
              if (info!.sizeLabel.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('大小:${info.sizeLabel}  当前:v${_check!.currentVersion}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ),
              Text(notes, style: const TextStyle(fontSize: 13, height: 1.4)),
            ]));
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
          SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(height: 12),
          Text('下载完成,请在系统弹出的安装界面确认安装。',
              style: TextStyle(fontSize: 13, height: 1.4)),
        ]);
    }
  }
}

enum _S { checking, available, latest, error, downloading, installing }
