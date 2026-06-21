// test/oem_whitelist_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:astrbot_app/util/oem_whitelist.dart';

OemInfo _info({String m = '', String b = '', bool p = false}) =>
    OemInfo(manufacturer: m, brand: b, hasPowerGenie: p);

void main() {
  group('whitelistGuideFor — 需要引导的厂商', () {
    test('荣耀(manufacturer HONOR)', () {
      final g = whitelistGuideFor(_info(m: 'HONOR'));
      expect(g.needsGuide, true);
      expect(g.oemKey, 'honor_huawei');
      expect(g.steps, isNotEmpty);
    });
    test('荣耀(brand honor)', () {
      expect(whitelistGuideFor(_info(b: 'honor')).needsGuide, true);
    });
    test('华为(manufacturer HUAWEI)', () {
      final g = whitelistGuideFor(_info(m: 'HUAWEI'));
      expect(g.needsGuide, true);
      expect(g.oemKey, 'honor_huawei');
    });
    test('PowerGenie 已安装(即便 manufacturer 为空)→ 荣耀/华为', () {
      // 旧款荣耀可能 Build.MANUFACTURER 报 HUAWEI 或空;hasPowerGenie 是最可靠信号。
      expect(whitelistGuideFor(_info(p: true)).needsGuide, true);
    });
    test('小米 / Redmi / POCO', () {
      expect(whitelistGuideFor(_info(m: 'Xiaomi')).oemKey, 'xiaomi');
      expect(whitelistGuideFor(_info(b: 'Redmi')).oemKey, 'xiaomi');
      expect(whitelistGuideFor(_info(b: 'POCO')).oemKey, 'xiaomi');
    });
    test('OPPO / OnePlus / Realme', () {
      expect(whitelistGuideFor(_info(m: 'OPPO')).oemKey, 'oppo');
      expect(whitelistGuideFor(_info(m: 'OnePlus')).oemKey, 'oppo');
      expect(whitelistGuideFor(_info(b: 'realme')).oemKey, 'oppo');
    });
    test('vivo / iQOO', () {
      expect(whitelistGuideFor(_info(m: 'vivo')).oemKey, 'vivo');
      expect(whitelistGuideFor(_info(b: 'IQOO')).oemKey, 'vivo');
    });
  });

  group('whitelistGuideFor — 不需引导', () {
    test('原生 Android(Pixel/Google)→ none', () {
      final g = whitelistGuideFor(_info(m: 'Google', b: 'google'));
      expect(g.needsGuide, false);
      expect(g, same(OemWhitelistGuide.none));
    });
    test('未知厂商 → none', () {
      expect(whitelistGuideFor(_info()).needsGuide, false);
    });
  });

  group('whitelistGuideFor — 描述品牌中立', () {
    // 引导文案不点名具体厂商(荣耀/华为/小米/OPPO/vivo 等),统一用「某些机型」。
    const _brandWords = [
      '荣耀', '华为', '小米', 'OPPO', 'OnePlus', 'Realme', 'vivo', 'iQOO',
      'MIUI', 'HyperOS', 'ColorOS', 'OriginOS', 'Funtouch', 'PowerGenie',
    ];
    for (final info in [
      _info(m: 'HONOR'),
      _info(m: 'HUAWEI'),
      _info(p: true),
      _info(m: 'Xiaomi'),
      _info(m: 'OPPO'),
      _info(m: 'vivo'),
    ]) {
      test('reason 不含品牌名 (${info.manufacturer}/${info.brand}/pg=${info.hasPowerGenie})', () {
        final g = whitelistGuideFor(info);
        expect(g.needsGuide, true);
        expect(g.reason, contains('某些机型'));
        for (final w in _brandWords) {
          expect(g.reason, isNot(contains(w)),
              reason: 'reason 不应点名品牌「$w」');
        }
      });
    }
  });

  group('OemInfo', () {
    test('isValid', () {
      expect(const OemInfo(manufacturer: '', brand: '').isValid, false);
      expect(const OemInfo(manufacturer: 'X', brand: '').isValid, true);
    });
  });
}
