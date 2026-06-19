// test/outbound_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/models/message.dart';
import 'package:astrbot_app/util/outbound.dart';

LocalMessage _msg({
  required int createdAt,
  MessageStatus status = MessageStatus.sent,
  bool isFromMe = true,
  String content = 'hi',
}) =>
    LocalMessage(
      msgType: 'text',
      content: content,
      isFromMe: isFromMe,
      status: status,
      createdAt: createdAt,
    );

void main() {
  group('interruptedBotText', () {
    test('空/空白返回 null', () {
      expect(interruptedBotText(null), isNull);
      expect(interruptedBotText(''), isNull);
      expect(interruptedBotText('   '), isNull);
    });
    test('有内容追加中断后缀', () {
      expect(interruptedBotText('一半回复'), '一半回复\n\n_(回复中断,请重试)_');
    });
  });

  group('markOutboundError', () {
    test('把指定 createdAt 的我发出消息置 error', () {
      final msgs = [_msg(createdAt: 100), _msg(createdAt: 200)];
      final out = markOutboundError(msgs, 100);
      expect(out[0].status, MessageStatus.error);
      expect(out[1].status, MessageStatus.sent); // 未误伤
    });
    test('不碰对方消息', () {
      final msgs = [_msg(createdAt: 100, isFromMe: false)];
      expect(markOutboundError(msgs, 100)[0].status, MessageStatus.sent);
    });
    test('找不到时不抛错(原样返回)', () {
      final msgs = [_msg(createdAt: 100)];
      expect(markOutboundError(msgs, 999).length, 1);
    });
  });

  group('setMessagePending', () {
    test('把指定消息回退为 pending', () {
      final msgs = [_msg(createdAt: 100, status: MessageStatus.error)];
      final out = setMessagePending(msgs, 100);
      expect(out[0].status, MessageStatus.pending);
    });
    test('不影响其它消息', () {
      final msgs = [_msg(createdAt: 100), _msg(createdAt: 200)];
      final out = setMessagePending(msgs, 100);
      expect(out[0].status, MessageStatus.pending);
      expect(out[1].status, MessageStatus.sent);
    });
  });
}
