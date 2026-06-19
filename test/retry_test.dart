// test/retry_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:astrbot_app/util/retry.dart';

void main() {
  group('isTransientDioError', () {
    test('连接超时/发送超时/接收超时/连接错误视为瞬态', () {
      for (final t in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.connectionError,
      ]) {
        expect(
            isTransientDioError(
                DioException(requestOptions: RequestOptions(), type: t)),
            isTrue,
            reason: '$t 应为瞬态');
      }
    });
    test('4xx 响应与 cancel 不重试', () {
      expect(
          isTransientDioError(DioException(
              requestOptions: RequestOptions(),
              type: DioExceptionType.badResponse,
              response: Response(requestOptions: RequestOptions(), statusCode: 400))),
          isFalse);
      expect(
          isTransientDioError(DioException(
              requestOptions: RequestOptions(), type: DioExceptionType.cancel)),
          isFalse);
    });
    test('非 DioException 默认不重试', () {
      expect(isTransientDioError(StateError('x')), isFalse);
    });
  });

  group('withRetry', () {
    test('成功则不重试,直接返回值', () async {
      var calls = 0;
      final r = await withRetry(() async {
        calls++;
        return 42;
      },
          isTransient: (_) => true,
          maxAttempts: 3,
          delayFor: (_) => Duration.zero);
      expect(r, 42);
      expect(calls, 1);
    });
    test('瞬态错误重试到成功', () async {
      var calls = 0;
      final r = await withRetry(() async {
        calls++;
        if (calls < 3) {
          throw DioException(
              requestOptions: RequestOptions(),
              type: DioExceptionType.connectionTimeout);
        }
        return 'ok';
      },
          isTransient: isTransientDioError,
          maxAttempts: 5,
          delayFor: (_) => Duration.zero);
      expect(r, 'ok');
      expect(calls, 3);
    });
    test('达到上限仍失败则抛最后一次错误', () async {
      expect(
          () => withRetry(() async {
                throw DioException(
                    requestOptions: RequestOptions(),
                    type: DioExceptionType.connectionError);
              },
              isTransient: isTransientDioError,
              maxAttempts: 3,
              delayFor: (_) => Duration.zero),
          throwsA(isA<DioException>()));
      // 给 future 跑完
      await Future.delayed(Duration.zero);
    });
    test('非瞬态错误立即抛出不重试', () async {
      var calls = 0;
      expect(
          () => withRetry(() async {
                calls++;
                throw StateError('boom');
              },
              isTransient: (_) => false,
              maxAttempts: 3,
              delayFor: (_) => Duration.zero),
          throwsA(isA<StateError>()));
      await Future.delayed(Duration.zero);
      expect(calls, 1);
    });
  });
}
