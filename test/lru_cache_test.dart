// test/lru_cache_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/util/lru_cache.dart';

void main() {
  test('超过容量淘汰最早写入的键', () {
    final c = LruCache<String, int>(maxSize: 2);
    c['a'] = 1;
    c['b'] = 2;
    expect(c.containsKey('a'), isTrue);
    c['c'] = 3; // 容量 2,淘汰 a
    expect(c.containsKey('a'), isFalse);
    expect(c['b'], 2);
    expect(c['c'], 3);
  });
  test('访问(key)后该键移到最新,不被淘汰', () {
    final c = LruCache<String, int>(maxSize: 2);
    c['a'] = 1;
    c['b'] = 2;
    expect(c['a'], 1); // 访问 a
    c['c'] = 3; // 淘汰 b
    expect(c['a'], 1);
    expect(c.containsKey('b'), isFalse);
  });
  test('同名键覆盖不增容', () {
    final c = LruCache<String, int>(maxSize: 2);
    c['a'] = 1;
    c['a'] = 11;
    c['b'] = 2;
    expect(c['a'], 11);
    expect(c.length, 2);
  });
  test('清空', () {
    final c = LruCache<String, int>(maxSize: 2)..['a'] = 1;
    c.clear();
    expect(c.length, 0);
  });
}
