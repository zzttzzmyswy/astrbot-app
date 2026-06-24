// lib/widgets/account_drawer.dart
//
// 左侧账户选择栏：列表/添加/重命名/编辑凭据/删除。最多 25（上限由 provider 拦截）。
// 风格与聊天页统一：accent 0xFF5B4BD6。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/account.dart';
import '../providers/chat_provider.dart';
import '../screens/account_editor_screen.dart';

class AccountDrawer extends ConsumerWidget {
  const AccountDrawer({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const accent = Color(0xFF5B4BD6);
    final bg = isDark ? const Color(0xFF151518) : const Color(0xFFFAFAFB);
    final card = isDark ? const Color(0xFF212121) : const Color(0xFFF2F2F6);
    final cardActive =
        isDark ? const Color(0xFF2A2A45) : const Color(0xFFECE9FB);
    final fg = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final sub = isDark ? const Color(0xFF9E9EA4) : const Color(0xFF8A8A8E);
    final div = isDark ? const Color(0xFF2A2A2E) : const Color(0xFFE5E5EA);

    final accounts = state.accounts;
    final current = state.currentAccountId;

    return Drawer(
      backgroundColor: bg,
      elevation: 0,
      width: 308,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          colors: [accent, Color(0xFF7661D8)]),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(Icons.smart_toy_rounded,
                        color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Text('账户',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700, color: fg)),
                  const Spacer(),
                  _NewButton(
                      accent: accent,
                      isDark: isDark,
                      fg: fg,
                      onTap: () => _onNew(context, ref)),
                ],
              ),
            ),
            Divider(height: 1, thickness: 0.5, color: div),
            Expanded(
              child: accounts.isEmpty
                  ? _Empty(sub: sub)
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      children: [
                        for (final a in accounts)
                          _AccountTile(
                            name: a.displayName,
                            subtitle:
                                '${_host(a.serverUrl)} · ${_relTime(a.lastUsedAt)}',
                            isCurrent: a.id == current,
                            isDark: isDark,
                            card: card,
                            cardActive: cardActive,
                            fg: fg,
                            sub: sub,
                            accent: accent,
                            onTap: () => _onSelect(context, ref, a.id),
                            onRename: () => _onRename(context, ref, a),
                            onEdit: () => _onEdit(context, a),
                            onDelete: () => _onDelete(context, ref, a),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _host(String url) {
    try {
      final h = Uri.parse(url).host;
      return h.isNotEmpty ? h : (url.length > 24 ? '${url.substring(0, 24)}…' : url);
    } catch (_) {
      return url.length > 24 ? '${url.substring(0, 24)}…' : url;
    }
  }

  String _relTime(int ms) {
    final diff = DateTime.now().millisecondsSinceEpoch - ms;
    if (diff < 60000) return '刚刚';
    if (diff < 3600000) return '${diff ~/ 60000}分钟前';
    if (diff < 86400000) return '${diff ~/ 3600000}小时前';
    if (diff < 7 * 86400000) return '${diff ~/ 86400000}天前';
    final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    return '${d.month}-${d.day}';
  }

  void _onNew(BuildContext context, WidgetRef ref) async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => const AccountEditorScreen()));
    if (ok == true && context.mounted) Navigator.of(context).pop();
  }

  void _onSelect(BuildContext context, WidgetRef ref, String id) async {
    Navigator.of(context).pop();
    await ref.read(chatProvider.notifier).selectAccount(id);
  }

  void _onRename(BuildContext context, WidgetRef ref, Account a) {
    final ctrl = TextEditingController(text: a.label ?? a.displayName);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名账户'),
        content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                ref
                    .read(chatProvider.notifier)
                    .renameAccount(a.id, ctrl.text);
              },
              child: const Text('保存')),
        ],
      ),
    );
  }

  void _onEdit(BuildContext context, Account a) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AccountEditorScreen(
              editId: a.id,
              initialLabel: a.label,
              initialServerUrl: a.serverUrl,
              initialToken: a.token,
            )));
  }

  void _onDelete(BuildContext context, WidgetRef ref, Account a) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账户'),
        content: Text('确定删除「${a.displayName}」?该账户本地消息将被清除,且无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除',
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    ).then((confirmed) async {
      if (confirmed == true) {
        if (!context.mounted) return;
        Navigator.of(context).pop();
        await ref.read(chatProvider.notifier).deleteAccount(a.id);
      }
    });
  }
}

class _NewButton extends StatelessWidget {
  final Color accent;
  final bool isDark;
  final Color fg;
  final VoidCallback onTap;
  const _NewButton(
      {required this.accent,
      required this.isDark,
      required this.fg,
      required this.onTap});
  @override
  Widget build(BuildContext context) => Material(
        color: accent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.add_rounded, color: Colors.white, size: 18),
              SizedBox(width: 2),
              Text('添加',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
}

class _AccountTile extends StatelessWidget {
  final String name, subtitle;
  final bool isCurrent, isDark;
  final Color card, cardActive, fg, sub, accent;
  final VoidCallback onTap, onRename, onEdit, onDelete;
  const _AccountTile({
    required this.name,
    required this.subtitle,
    required this.isCurrent,
    required this.isDark,
    required this.card,
    required this.cardActive,
    required this.fg,
    required this.sub,
    required this.accent,
    required this.onTap,
    required this.onRename,
    required this.onEdit,
    required this.onDelete,
  });
  @override
  Widget build(BuildContext context) {
    final initial =
        name.isNotEmpty ? name.characters.first.toUpperCase() : '?';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Material(
        color: isCurrent ? cardActive : card,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
            child: Row(
              children: [
                if (isCurrent)
                  Container(
                      width: 3,
                      height: 30,
                      decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(2))),
                if (isCurrent)
                  const SizedBox(width: 8)
                else
                  const SizedBox(width: 11),
                Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                        color: accent, borderRadius: BorderRadius.circular(12)),
                    child: Text(initial,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700))),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: isCurrent
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: fg)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: sub)),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_horiz, color: sub, size: 20),
                  padding: EdgeInsets.zero,
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('重命名')),
                    PopupMenuItem(value: 'edit', child: Text('编辑凭据')),
                    PopupMenuItem(
                        value: 'delete',
                        child: Text('删除',
                            style: TextStyle(color: Colors.redAccent))),
                  ],
                  onSelected: (v) {
                    if (v == 'rename') onRename();
                    if (v == 'edit') onEdit();
                    if (v == 'delete') onDelete();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final Color sub;
  const _Empty({required this.sub});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.smart_toy_outlined,
                  size: 44, color: sub.withValues(alpha: 0.6)),
              const SizedBox(height: 12),
              Text('暂无账户', style: TextStyle(color: sub, fontSize: 14)),
              const SizedBox(height: 4),
              Text('点击右上角「添加」',
                  style: TextStyle(color: sub.withValues(alpha: 0.7), fontSize: 12)),
            ],
          ),
        ),
      );
}
