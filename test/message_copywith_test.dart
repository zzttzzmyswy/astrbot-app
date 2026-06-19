import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/models/message.dart';

void main() {
  test('copyWith(uploadProgress: null) clears the field, not falls back to old', () {
    final m = LocalMessage(
      msgType: 'image',
      isFromMe: true,
      status: MessageStatus.uploading,
      uploadProgress: 0.42,
      createdAt: 1,
    );
    // 显式传 null = 清空
    final cleared = m.copyWith(uploadProgress: null);
    expect(cleared.uploadProgress, isNull);

    // 不传该参数 = 保持旧值
    final kept = m.copyWith(status: MessageStatus.sent);
    expect(kept.uploadProgress, 0.42);

    // 传具体值 = 覆盖
    final updated = m.copyWith(uploadProgress: 0.9);
    expect(updated.uploadProgress, 0.9);
  });
}
