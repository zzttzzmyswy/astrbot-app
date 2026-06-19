// test/version_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/util/version.dart';

void main() {
  test('相等', () {
    expect(compareVersions('1.0.0', '1.0.0'), 0);
    expect(compareVersions('v1.0.0', '1.0.0'), 0);
  });
  test('主版本大者大', () {
    expect(compareVersions('2.0.0', '1.9.9'), 1);
    expect(compareVersions('1.9.9', '2.0.0'), -1);
  });
  test('次版本/修订号递进', () {
    expect(compareVersions('1.1.0', '1.0.5'), 1);
    expect(compareVersions('1.0.10', '1.0.9'), 1);
    expect(compareVersions('1.0.0', '1.0.1'), -1);
  });
  test('段数不同(1.0 vs 1.0.0)', () {
    expect(compareVersions('1.0', '1.0.0'), 0);
    expect(compareVersions('1.0', '1.0.1'), -1);
  });
}
