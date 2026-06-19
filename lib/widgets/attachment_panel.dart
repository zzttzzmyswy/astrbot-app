// lib/widgets/attachment_panel.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';

class AttachmentPanel extends ConsumerStatefulWidget {
  final VoidCallback? onClose;
  final void Function(File file)? onPickImage;
  final void Function(File file, String filename, String mime)? onPickFile;

  const AttachmentPanel({super.key, this.onClose, this.onPickImage, this.onPickFile});

  @override
  ConsumerState<AttachmentPanel> createState() => _AttachmentPanelState();
}

class _AttachmentPanelState extends ConsumerState<AttachmentPanel> {
  final _picker = ImagePicker();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final handleColor = isDark ? const Color(0xFF4A4A4E) : const Color(0xFFD1D1D6);
    final labelColor = isDark ? const Color(0xFFAEAEB2) : const Color(0xFF6B6B70);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.07),
            blurRadius: 14,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 6),
              width: 38, height: 4,
              decoration: BoxDecoration(color: handleColor, borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _Option(
                    icon: Icons.camera_alt_rounded,
                    label: '拍照',
                    labelColor: labelColor,
                    isDark: isDark,
                    onTap: () => _capture(ImageSource.camera),
                  ),
                  _Option(
                    icon: Icons.photo_library_rounded,
                    label: '相册',
                    labelColor: labelColor,
                    isDark: isDark,
                    onTap: () => _capture(ImageSource.gallery),
                  ),
                  _Option(
                    icon: Icons.insert_drive_file_rounded,
                    label: '文件',
                    labelColor: labelColor,
                    isDark: isDark,
                    onTap: () => _pickFile(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _capture(ImageSource source) async {
    try {
      if (source == ImageSource.camera) {
        final status = await Permission.camera.request();
        if (!status.isGranted) {
          if (mounted) _showError('相机权限未授予');
          return;
        }
      }
      final XFile? xfile = await _picker.pickImage(source: source, imageQuality: 85);
      if (xfile == null) return;
      widget.onClose?.call();
      widget.onPickImage?.call(File(xfile.path));
    } catch (e) {
      if (mounted) _showError('拍照失败: $e');
    }
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.isEmpty) return;
      final file = File(result.files.single.path!);
      final filename = result.files.single.name;
      final ext = result.files.single.extension ?? 'bin';
      final mime = _mimeForExt(ext);
      widget.onClose?.call();
      widget.onPickFile?.call(file, filename, mime);
    } catch (e) {
      if (mounted) _showError('选择文件失败: $e');
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.redAccent));
  }

  String _mimeForExt(String ext) {
    switch (ext.toLowerCase()) {
      case 'jpg': case 'jpeg': return 'image/jpeg';
      case 'png': return 'image/png';
      case 'gif': return 'image/gif';
      case 'pdf': return 'application/pdf';
      case 'txt': return 'text/plain';
      case 'mp4': return 'video/mp4';
      case 'mp3': return 'audio/mpeg';
      case 'wav': return 'audio/wav';
      default: return 'application/octet-stream';
    }
  }
}

class _Option extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color labelColor;
  final bool isDark;
  final VoidCallback onTap;

  const _Option({
    required this.icon,
    required this.label,
    required this.labelColor,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Unified with the rest of the app: a single accent (the same purple used
    // by the send button and attachment-bubble icon blocks) on a soft tinted
    // tile, instead of per-option multi-color gradients.
    const accent = Color(0xFF5B4BD6);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 76,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56, height: 56,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: isDark ? 0.22 : 0.10),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(icon, color: accent, size: 24),
            ),
            const SizedBox(height: 7),
            Text(label, style: TextStyle(color: labelColor, fontSize: 12, fontWeight: FontWeight.w500), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
