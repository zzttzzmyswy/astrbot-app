// lib/util/reconnect.dart

/// 指数退避重连延迟(纯函数,无 Timer)。
/// attempt = 已经失败并即将重试的次数(0 = 第一次失败后)。
/// delay = baseMs * 2^attempt,封顶 maxMs。与 WS 现有 1s→2s→…→30s 一致。
int reconnectDelayMs(int attempt, {required int baseMs, required int maxMs}) {
  final raw = baseMs * (1 << attempt); // 2^attempt
  return raw > maxMs ? maxMs : raw;
}

/// 维护重连计数的小状态机:成功清零,失败递增并给出下次延迟。
class ReconnectAttempt {
  int _count = 0;
  int get count => _count;
  void recordFailure() => _count++;
  void reset() => _count = 0;
  int nextDelay({required int baseMs, required int maxMs}) =>
      reconnectDelayMs(_count, baseMs: baseMs, maxMs: maxMs);
}
