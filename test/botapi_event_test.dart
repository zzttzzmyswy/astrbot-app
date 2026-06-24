// test/botapi_event_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/models/botapi_event.dart';

void main() {
  group('BotApiEvent.fromSse', () {
    test('message text streaming', () {
      final e = BotApiEvent.fromSse('message', {
        'message_id': 'botapi_abc', 'type': 'text', 'content': '你好',
        'streaming': true, 'timestamp': 1719234567,
      });
      expect(e.event, 'message');
      expect(e.type, 'text');
      expect(e.content, '你好');
      expect(e.streaming, true);
      expect(e.isFinal, isNull);
      expect(e.messageId, 'botapi_abc');
    });
    test('message text final 自纠正', () {
      final e = BotApiEvent.fromSse('message', {
        'message_id': 'botapi_abc', 'type': 'text', 'content': '完整答案',
        'final': true,
      });
      expect(e.isFinal, true);
      expect(e.streaming, isNull);
    });
    test('message tool_status 不并入答案', () {
      final e = BotApiEvent.fromSse('message', {
        'type': 'text', 'subtype': 'tool_status', 'content': '🔨 调用工具',
      });
      expect(e.subtype, 'tool_status');
      expect(e.isToolStatus, true);
    });
    test('message file content 为对象', () {
      final e = BotApiEvent.fromSse('message', {
        'type': 'file', 'content': {'name': 'a.pdf', 'url': 'http://x/y'},
      });
      expect(e.type, 'file');
      expect(e.content, contains('a.pdf'));
      expect(e.isMedia, true);
    });
    test('thinking', () {
      final e = BotApiEvent.fromSse('thinking', {'content': '思考中', 'streaming': true});
      expect(e.event, 'thinking');
      expect(e.content, '思考中');
      expect(e.isThinking, true);
    });
    test('error SESSION_KICKED', () {
      final e = BotApiEvent.fromSse('error', {'code': 'SESSION_KICKED', 'message': '管理员已断开'});
      expect(e.code, 'SESSION_KICKED');
      expect(e.message, '管理员已断开');
      expect(e.isError, true);
    });
    test('ping 忽略但不抛', () {
      final e = BotApiEvent.fromSse('ping', {});
      expect(e.event, 'ping');
      expect(e.isPing, true);
    });
    test('image isMedia', () {
      final e = BotApiEvent.fromSse('message', {'type': 'image', 'content': 'http://x/y.jpg'});
      expect(e.isMedia, true);
      expect(e.isStreamingText, false);
    });
  });
}
