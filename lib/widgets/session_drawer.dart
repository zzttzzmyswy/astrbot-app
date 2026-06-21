// lib/widgets/session_drawer.dart
//
// 左侧会话选择栏:由 Scaffold.drawer 承载,左边缘右滑自动拉出。
// 列出本地会话注册表:选择 / 新建 / 改名 / 删除。最多 25 个(上限由 provider 拦截)。
// 风格与聊天页统一:accent 0xFF5B4BD6、圆角 16、明暗卡片色。
// 占位会话(kPendingSessionId,尚未由服务端分配 id)在顶部显示为「新会话」高亮项。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_session.dart';
import '../providers/chat_provider.dart';
import '../services/session_store.dart';

class SessionDrawer extends ConsumerWidget {
  const SessionDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const accent = Color(0xFF5B4BD6);
    final bg = isDark ? const Color(0xFF151518) : const Color(0xFFFAFAFB);
    final card = isDark ? const Color(0xFF212121) : const Color(0xFFF2F2F6);
    final cardActive = isDark ? const Color(0xFF2A2A45) : const Color(0xFFECE9FB);
    final fg = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final sub = isDark ? const Color(0xFF9E9EA4) : const Color(0xFF8A8A8E);
    final div = isDark ? const Color(0xFF2A2A2E) : const Color(0xFFE5E5EA);

    final sessions = state.sessions;
    final current = state.currentSessionId;
    final isPending = current == kPendingSessionId;

    return Drawer(
      backgroundColor: bg,
      elevation: 0,
      width: 308,
      child: SafeArea(
        child: Column(
          children: [
            // 头部:标题 + 新建按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  Container(
                    width: 32, height: 32, alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          colors: [accent, Color(0xFF7661D8)]),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(Icons.chat_rounded, color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Text('会话',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700, color: fg)),
                  const Spacer(),
                  _NewButton(
                    accent: accent,
                    fg: fg,
                    isDark: isDark,
                    onTap: () => _onNew(context, ref),
                  ),
                ],
              ),
            ),
            Divider(height: 1, thickness: 0.5, color: div),
            // 列表
            Expanded(
              child: sessions.isEmpty && !isPending
                  ? _Empty(sub: sub)
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      children: [
                        // 占位会话(未发送)顶部高亮项
                        if (isPending)
                          _SessionTile(
                            name: '新会话',
                            subtitle: '发送消息以创建',
                            isCurrent: true,
                            isDark: isDark,
                            card: card,
                            cardActive: cardActive,
                            fg: fg,
                            sub: sub,
                            accent: accent,
                            onTap: () {}, // 已是当前,空操作
                            onRename: null,
                            onDelete: null,
                            leadingIcon: Icons.add_comment_outlined,
                          ),
                        for (final s in sessions)
                          _SessionTile(
                            name: s.displayName,
                            subtitle:
                                '#${s.id.length >= 6 ? s.id.substring(0, 6) : s.id} · ${_relTime(s.lastUsedAt)}',
                            isCurrent: s.id == current,
                            isDark: isDark,
                            card: card,
                            cardActive: cardActive,
                            fg: fg,
                            sub: sub,
                            accent: accent,
                            onTap: () => _onSelect(context, ref, s.id),
                            onRename: () => _onRename(context, ref, s),
                            onDelete: () => _onDelete(context, ref, s),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _relTime(int ms) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = now - ms;
    if (diff < 60000) return '刚刚';
    if (diff < 3600000) return '${diff ~/ 60000} 分钟前';
    if (diff < 86400000) return '${diff ~/ 3600000} 小时前';
    if (diff < 7 * 86400000) return '${diff ~/ 86400000} 天前';
    final d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    return '${d.month}-${d.day}';
  }

  void _onNew(BuildContext context, WidgetRef ref) async {
    final ok = await ref.read(chatProvider.notifier).createSession();
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已达 25 个会话上限,请先删除一些会话')),
      );
      return;
    }
    Navigator.of(context).pop();
  }

  void _onSelect(BuildContext context, WidgetRef ref, String id) async {
    Navigator.of(context).pop(); // 先收起抽屉,再切换(避免重连时抽屉遮挡)
    await ref.read(chatProvider.notifier).selectSession(id);
  }

  void _onRename(BuildContext context, WidgetRef ref, ChatSession s) {
    final ctrl = TextEditingController(text: s.name ?? s.displayName);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            hintText: '会话名称',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(chatProvider.notifier).renameSession(s.id, ctrl.text);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _onDelete(BuildContext context, WidgetRef ref, ChatSession s) {
    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确定删除「${s.displayName}」?该会话的本地消息将被清除,且无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    ).then((confirmed) async {
      if (confirmed == true) {
        if (!context.mounted) return;
        Navigator.of(context).pop(); // 收起抽屉
        await ref.read(chatProvider.notifier).deleteSession(s.id);
      }
    });
  }
}

class _NewButton extends StatelessWidget {
  final Color accent;
  final Color fg;
  final bool isDark;
  final VoidCallback onTap;
  const _NewButton({required this.accent, required this.fg, required this.isDark, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
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
            Text('新建', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final String name;
  final String subtitle;
  final bool isCurrent;
  final bool isDark;
  final Color card, cardActive, fg, sub, accent;
  final VoidCallback onTap;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;
  final IconData? leadingIcon;
  const _SessionTile({
    required this.name, required this.subtitle, required this.isCurrent,
    required this.isDark, required this.card, required this.cardActive,
    required this.fg, required this.sub, required this.accent,
    required this.onTap, this.onRename, this.onDelete, this.leadingIcon,
  });

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name.characters.first.toUpperCase() : '?';
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
                // 左侧 accent 条:当前会话高亮
                if (isCurrent)
                  Container(
                      width: 3, height: 30,
                      decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2))),
                if (isCurrent) const SizedBox(width: 8) else const SizedBox(width: 11),
                // 头像
                Container(
                  width: 38, height: 38, alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: leadingIcon != null
                        ? accent.withValues(alpha: isDark ? 0.28 : 0.14)
                        : accent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: leadingIcon != null
                      ? Icon(leadingIcon, color: accent, size: 20)
                      : Text(initial,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                ),
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
                              fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                              color: fg)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: sub)),
                    ],
                  ),
                ),
                if (onRename != null || onDelete != null)
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_horiz, color: sub, size: 20),
                    padding: EdgeInsets.zero,
                    itemBuilder: (_) => [
                      if (onRename != null)
                        const PopupMenuItem(value: 'rename', child: Text('重命名')),
                      if (onDelete != null)
                        const PopupMenuItem(
                            value: 'delete',
                            child: Text('删除', style: TextStyle(color: Colors.redAccent))),
                    ],
                    onSelected: (v) {
                      if (v == 'rename') onRename?.call();
                      if (v == 'delete') onDelete?.call();
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
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.forum_outlined, size: 44, color: sub.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text('暂无会话', style: TextStyle(color: sub, fontSize: 14)),
            const SizedBox(height: 4),
            Text('点击右上角「新建」开始', style: TextStyle(color: sub.withValues(alpha: 0.7), fontSize: 12)),
          ]),
        ),
      );
}
