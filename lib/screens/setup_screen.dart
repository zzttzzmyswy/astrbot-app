// lib/screens/setup_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/chat_provider.dart';
import 'chat_screen.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});
  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _labelCtrl = TextEditingController();
  final _serverCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  bool _revealed = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _labelCtrl.dispose();
    _serverCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _onSave() async {
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
    final ok = await ref.read(chatProvider.notifier).addAccount(
        serverUrl: server, token: token, label: _labelCtrl.text.trim());
    if (!mounted) return;
    if (ok) {
      Navigator.of(context)
          .pushReplacement(MaterialPageRoute(builder: (_) => const ChatScreen()));
    } else {
      setState(() {
        _saving = false;
        _error = '添加失败（已达账户上限 25?）';
      });
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
              const Icon(Icons.smart_toy_rounded,
                  size: 56, color: Color(0xFF4A9EFF)),
              const SizedBox(height: 12),
              const Text('欢迎使用 Bot助手',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text('添加一个 botapi 账户即可开始',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                  textAlign: TextAlign.center),
              const SizedBox(height: 32),
              _field('名称（可选）', _labelCtrl),
              const SizedBox(height: 12),
              _field('服务器地址', _serverCtrl,
                  hint: 'https://your-host/api/v1/botapi'),
              const SizedBox(height: 12),
              _field('Token', _tokenCtrl,
                  obscure: !_revealed,
                  suffix: IconButton(
                    icon: Icon(
                        _revealed
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 20),
                    onPressed: () => setState(() => _revealed = !_revealed),
                  )),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.redAccent)),
                ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _saving ? null : _onSave,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF4A9EFF),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('开始聊天', style: TextStyle(fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController ctrl,
          {bool obscure = false, String? hint, Widget? suffix}) =>
      TextField(
        controller: ctrl,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          suffixIcon: suffix,
          border:
              OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      );
}
