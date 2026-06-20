// lib/widgets/oem_whitelist_dialog.dart
//
// 后台白名单引导对话框:展示原因 + 步骤 + 「去设置」按钮(打开系统后台管理页)。
// 用于荣耀/华为等机型 —— 其默认会冻结/杀死后台应用,是「切后台就断连、消息丢失」根因。
import 'package:flutter/material.dart';
import '../services/device_oem_service.dart';
import '../util/oem_whitelist.dart';

class OemWhitelistDialog extends StatefulWidget {
  final OemWhitelistGuide guide;
  const OemWhitelistDialog({super.key, required this.guide});

  @override
  State<OemWhitelistDialog> createState() => _OemWhitelistDialogState();
}

class _OemWhitelistDialogState extends State<OemWhitelistDialog> {
  final _oem = const DeviceOemService();

  @override
  Widget build(BuildContext context) {
    final g = widget.guide;
    return AlertDialog(
      title: Text(g.title),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(g.reason, style: const TextStyle(fontSize: 13, height: 1.4)),
            const SizedBox(height: 12),
            const Text('操作步骤:',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            ...g.steps.asMap().entries.map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${e.key + 1}. ',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                        Expanded(
                          child: Text(e.value,
                              style: const TextStyle(
                                  fontSize: 13, height: 1.35)),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('稍后再说'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.settings, size: 18),
          label: const Text('去设置'),
          onPressed: () async {
            await _oem.openAppLaunchSettings();
            if (context.mounted) Navigator.pop(context, true);
          },
        ),
      ],
    );
  }
}
