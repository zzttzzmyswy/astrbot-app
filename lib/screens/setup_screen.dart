// lib/screens/setup_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/config_provider.dart';
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
                '欢迎使用 Bot助手',
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
