// test/stream_text_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/models/botapi_event.dart';
import 'package:astrbot_app/util/stream_text.dart';

BotApiEvent _delta(String t) => BotApiEvent.fromSse('message', {
      'message_id': 'm1', 'type': 'text', 'content': t, 'streaming': true,
    });

BotApiEvent _segmentEnd(String full) => BotApiEvent.fromSse('message', {
      'message_id': 'm1',
      'type': 'text',
      'content': full,
      'streaming': true,
      'segment_end': true,
    });

BotApiEvent _final(String full) => BotApiEvent.fromSse('message', {
      'message_id': 'm1', 'type': 'text', 'content': full, 'final': true,
    });

void main() {
  group('accumulateStreamText', () {
    test('纯 delta 顺序累加', () {
      var s = '';
      s = accumulateStreamText(s, _delta('明'));
      expect(s, '明');
      s = accumulateStreamText(s, _delta('白'));
      expect(s, '明白');
    });

    test('segment_end 携本段累计全文，不得重复追加（修复翻倍）', () {
      // 服务端 event.py：先发各 delta，break 时再发本段累计全文 segment_end。
      var s = '';
      s = accumulateStreamText(s, _delta('明白，'));
      s = accumulateStreamText(s, _delta('仅分析不操作。'));
      // 段累计 = '明白，仅分析不操作。'，旧逻辑 cur+content 会翻倍
      s = accumulateStreamText(s, _segmentEnd('明白，仅分析不操作。'));
      expect(s, '明白，仅分析不操作。'); // 不翻倍
    });

    test('多段（agent 多次工具调用）不串段翻倍', () {
      var s = '';
      s = accumulateStreamText(s, _delta('第一段'));
      s = accumulateStreamText(s, _segmentEnd('第一段'));
      s = accumulateStreamText(s, _delta('第二段'));
      s = accumulateStreamText(s, _segmentEnd('第二段'));
      expect(s, '第一段第二段');
    });

    test('空 segment_end（buf 空时 break）无副作用', () {
      var s = '已存在';
      s = accumulateStreamText(s, _segmentEnd(''));
      expect(s, '已存在');
    });

    test('对照：旧逻辑 cur+content 会翻倍', () {
      // 显式证明被替换的旧逻辑确实翻倍，锁住回归。
      var s = '明白，仅分析不操作。';
      final oldLogic = s + '明白，仅分析不操作。';
      expect(oldLogic, '明白，仅分析不操作。明白，仅分析不操作。');
      expect(accumulateStreamText(s, _segmentEnd('明白，仅分析不操作。')),
          '明白，仅分析不操作。'); // 新逻辑不翻倍
    });

    test('非流式事件不动累积', () {
      var s = '明白';
      s = accumulateStreamText(s, _final('明白'));
      expect(s, '明白'); // final 不走流式累积（由 _commitBotText 单独处理）
    });
  });
}
