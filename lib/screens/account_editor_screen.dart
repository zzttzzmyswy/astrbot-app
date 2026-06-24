// lib/screens/account_editor_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/chat_provider.dart';
import '../util/key_mask.dart';

/// 添加 / 编辑账户。add 模式 editId=null；edit 模式传已有账户字段。
class AccountEditorScreen extends ConsumerStatefulWidget {
  final String? editId;
  final String? initialLabel;
  final String? initialServerUrl;
  final String? initialToken;
  const AccountEditorScreen({
    super.key,
    this.editId,
    this.initialLabel,
    this.initialServerUrl,
    this.initialToken,
  });
  @override
  ConsumerState<AccountEditorScreen> createState() => _AccountEditorScreenState();
}

class _AccountEditorScreenState extends ConsumerState<AccountEditorScreen> {
  late final TextEditingController _labelCtrl;
  late final TextEditingController _serverCtrl;
  late final TextEditingController _tokenCtrl;
  bool _revealed = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _labelCtrl = TextEditingController(text: widget.initialLabel ?? '');
    _serverCtrl = TextEditingController(text: widget.initialServerUrl ?? '');
    _tokenCtrl = TextEditingController(text: widget.initialToken ?? '');
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _serverCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  bool get _isEdit => widget.editId != null;

  Future<void> _save() async {
    final server = _serverCtrl.text.trim();
    final token = _tokenCtrl.text.trim();
    if (server.isEmpty || token.isEmpty) {
      setState(() => _error = '服务器地址与 Token 必填');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final notifier = ref.read(chatProvider.notifier);
    if (_isEdit) {
      await notifier.updateAccountCredentials(widget.editId!,
          serverUrl: server, token: token);
      await notifier.renameAccount(widget.editId!, _labelCtrl.text.trim());
      if (mounted) Navigator.of(context).pop(true);
    } else {
      final ok = await notifier.addAccount(
          serverUrl: server, token: token, label: _labelCtrl.text.trim());
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _saving = false;
          _error = '添加失败（已达账户上限 25?）';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokenPreview = (_isEdit && !_revealed && _tokenCtrl.text.isNotEmpty)
        ? maskKey(_tokenCtrl.text)
        : null;
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? '编辑账户' : '添加账户')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _labelCtrl,
                decoration: _dec('名称（可选）'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _serverCtrl,
                keyboardType: TextInputType.url,
                decoration: _dec('服务器地址', hint: 'https://your-host/api/v1/botapi'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _tokenCtrl,
                obscureText: !_revealed,
                decoration: _dec('Token',
                    suffix: IconButton(
                      icon: Icon(
                          _revealed
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          size: 20),
                      onPressed: () => setState(() => _revealed = !_revealed),
                    )),
              ),
              if (tokenPreview != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('当前: $tokenPreview',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                      overflow: TextOverflow.ellipsis),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.redAccent)),
                ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(_isEdit ? '保存' : '添加',
                        style: const TextStyle(fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _dec(String label, {String? hint, Widget? suffix}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        border:
            OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        suffixIcon: suffix,
      );
}
