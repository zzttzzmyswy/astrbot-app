// lib/util/retry.dart
import 'package:dio/dio.dart';

/// 判断一个错误是否值得重试(瞬态、网络相关)。
/// 4xx badResponse、cancel、unknown 默认不重试。
bool isTransientDioError(Object e) {
  if (e is! DioException) return false;
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionError:
      return true;
    case DioExceptionType.badResponse:
    case DioExceptionType.cancel:
    case DioExceptionType.unknown:
    case DioExceptionType.badCertificate:
      return false;
  }
}

/// 对 [action] 做最多 [maxAttempts] 次尝试。
/// 仅当 [isTransient](error) 为真才重试;否则立即抛出。
/// [delayFor] 给出第 i 次(0 起)失败后的等待,可传 Duration.zero 用于测试。
/// 成功返回值;全失败抛最后一次错误。
Future<T> withRetry<T>(
  Future<T> Function() action, {
  required bool Function(Object) isTransient,
  int maxAttempts = 3,
  required Duration Function(int attempt) delayFor,
}) async {
  Object? lastErr;
  for (int attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      return await action();
    } catch (e) {
      lastErr = e;
      if (!isTransient(e)) rethrow;
      if (attempt == maxAttempts - 1) break;
      await Future.delayed(delayFor(attempt));
    }
  }
  throw lastErr!;
}
