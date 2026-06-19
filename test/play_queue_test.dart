import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/services/play_queue.dart';

void main() {
  test('空闲 enqueue 立即成为当前', () {
    final q = PlayQueue();
    final next = q.enqueue('a');
    expect(next, 'a');
    expect(q.current, 'a');
    expect(q.queue, isEmpty);
  });

  test('忙时 enqueue 入队,markComplete 顺序出队', () {
    final q = PlayQueue();
    q.enqueue('a');          // 立即播放 a
    expect(q.enqueue('b'), isNull); // 正在播 a,b 入队,无即时返回
    expect(q.enqueue('c'), isNull);
    expect(q.queue, ['b', 'c']);
    expect(q.markComplete(), 'b');  // a 完 → 接 b
    expect(q.current, 'b');
    expect(q.markComplete(), 'c');  // b 完 → 接 c
    expect(q.markComplete(), isNull); // 队列空
    expect(q.current, isNull);
  });

  test('replaceCurrent 停旧播新但不清空待播队列', () {
    final q = PlayQueue();
    q.enqueue('a');
    q.enqueue('b');           // 待播 [b]
    expect(q.replaceCurrent('x'), 'x'); // 手动切 x
    expect(q.current, 'x');
    expect(q.queue, ['b']);   // 待播队列保留
  });

  test('clear 重置', () {
    final q = PlayQueue();
    q.enqueue('a'); q.enqueue('b');
    q.clear();
    expect(q.current, isNull);
    expect(q.queue, isEmpty);
  });
}
