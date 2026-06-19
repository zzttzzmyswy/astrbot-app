// lib/util/lru_cache.dart

/// 有序 LRU。读取/写入都会把键标记为最近使用;超出 maxSize 时淘汰最久未用。
/// 用普通 Map + remove/re-insert 实现访问序,语义正确且无特殊构造依赖。
class LruCache<K, V> {
  LruCache({this.maxSize = 32});
  final int maxSize;
  final _map = <K, V>{};

  int get length => _map.length;
  bool containsKey(K key) => _map.containsKey(key);

  V? operator [](K key) {
    final v = _map.remove(key); // 取出
    if (v == null) return null;
    _map[key] = v; // 重新插到末尾 = 最近使用
    return v;
  }

  void operator []=(K key, V value) {
    _map.remove(key);
    _map[key] = value;
    while (_map.length > maxSize) {
      _map.remove(_map.keys.first);
    }
  }

  void clear() => _map.clear();
}
