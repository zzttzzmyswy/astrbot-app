import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:astrbot_app/services/config_service.dart';

void main() {
  test('autoPlayVoice defaults to false and round-trips', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ConfigService();
    await c.init();
    expect(c.autoPlayVoice, isFalse);
    await c.setAutoPlayVoice(true);
    expect(c.autoPlayVoice, isTrue);
    await c.setAutoPlayVoice(false);
    expect(c.autoPlayVoice, isFalse);
  });
}
