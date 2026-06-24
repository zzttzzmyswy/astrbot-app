// test/botapi_http_base_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/services/botapi_http.dart';

void main() {
  group('botapiBase', () {
    test('已含 /api/v1/botapi 不重复拼接', () {
      expect(botapiBase('https://h/api/v1/botapi'), 'https://h/api/v1/botapi');
    });
    test('带尾斜杠去掉', () {
      expect(botapiBase('https://h/api/v1/botapi/'), 'https://h/api/v1/botapi');
    });
    test('纯 host 补全路径', () {
      expect(botapiBase('https://h'), 'https://h/api/v1/botapi');
    });
    test('host 带尾斜杠', () {
      expect(botapiBase('https://h/'), 'https://h/api/v1/botapi');
    });
    test('http 与端口', () {
      expect(botapiBase('http://1.2.3.4:9000'), 'http://1.2.3.4:9000/api/v1/botapi');
    });
    test('空串原样返回', () {
      expect(botapiBase(''), '');
    });
    test('带空格 trim', () {
      expect(botapiBase('  https://h/api/v1/botapi  '), 'https://h/api/v1/botapi');
    });
  });
}
