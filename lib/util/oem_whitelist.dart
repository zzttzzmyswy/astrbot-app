// lib/util/oem_whitelist.dart
//
// 后台白名单引导的纯逻辑(不碰平台调用,便于单测)。
// 厂商判定 + 对应设置路径文案。背景:国产 ROM(荣耀/华为/小米/OPPO/vivo 等)默认会
// 冻结/杀死后台应用,即便有前台保活服务也无效 —— 这是「切后台就断连、消息丢失」的
// 根因。需引导用户手动允许本应用后台运行。

class OemInfo {
  final String manufacturer;
  final String brand;
  final bool hasPowerGenie;

  const OemInfo({
    required this.manufacturer,
    required this.brand,
    this.hasPowerGenie = false,
  });

  static const OemInfo unknown = OemInfo(
    manufacturer: '',
    brand: '',
    hasPowerGenie: false,
  );

  /// 是否读取到有效厂商信息。
  bool get isValid => manufacturer.isNotEmpty || brand.isNotEmpty;
}

class OemWhitelistGuide {
  const OemWhitelistGuide({
    required this.needsGuide,
    required this.oemKey,
    required this.title,
    required this.reason,
    required this.steps,
  });

  final bool needsGuide;
  /// 'honor_huawei' | 'xiaomi' | 'oppo' | 'vivo' | 'samsung' | 'other'
  final String oemKey;
  final String title;
  final String reason;
  /// 有序步骤文案。
  final List<String> steps;

  static const OemWhitelistGuide none = OemWhitelistGuide(
    needsGuide: false,
    oemKey: 'other',
    title: '',
    reason: '',
    steps: <String>[],
  );
}

/// 通用引导文案(品牌中立):不点名具体厂商,只说「某些机型」。
const _kOemReason =
    '某些机型默认会冻结或杀死后台应用,即使有保活服务也无效 —— '
    '这是「bot 回复时切后台就断连、消息丢失」的根因。'
    '请按下方步骤允许本应用后台运行。';

/// 判定给定厂商是否需要后台白名单引导,并返回对应文案。
/// [manufacturer]/[brand] 大小写不敏感(内部归一化)。
/// [hasPowerGenie] 荣耀/华为 PowerGenie 是否安装 —— 该包只在荣耀/华为设备存在,
/// 是最可靠的信号(旧款荣耀可能 Build.MANUFACTURER 报 HUAWEI)。
OemWhitelistGuide whitelistGuideFor(OemInfo info) {
  final m = info.manufacturer.toLowerCase();
  final b = info.brand.toLowerCase();
  final honorHuawei = info.hasPowerGenie ||
      m == 'honor' || b == 'honor' ||
      m == 'huawei' || b == 'huawei';

  if (honorHuawei) {
    return const OemWhitelistGuide(
      needsGuide: true,
      oemKey: 'honor_huawei',
      title: '开启后台运行,避免消息丢失',
      reason: _kOemReason,
      steps: [
        '进入「设置 → 电池」',
        '点「应用启动管理」',
        '找到「Bot助手」,关闭其「自动管理」开关',
        '在弹窗中勾选全部三项:「允许自启动」「允许关联启动」「允许后台活动」',
      ],
    );
  }

  if (m == 'xiaomi' || b == 'xiaomi' || b == 'redmi' || b == 'poco') {
    return const OemWhitelistGuide(
      needsGuide: true,
      oemKey: 'xiaomi',
      title: '开启后台运行,避免消息丢失',
      reason: _kOemReason,
      steps: [
        '长按「Bot助手」图标 → 应用信息',
        '「省电策略」选「无限制」',
        '在「自启动」中允许本应用',
      ],
    );
  }

  if (m == 'oppo' || b == 'oppo' ||
      m == 'oneplus' || b == 'oneplus' ||
      m == 'realme' || b == 'realme') {
    return const OemWhitelistGuide(
      needsGuide: true,
      oemKey: 'oppo',
      title: '开启后台运行,避免消息丢失',
      reason: _kOemReason,
      steps: [
        '进入「设置 → 电池 → 更多(电池)设置 → 应用耗电管理」',
        '找到「Bot助手」,开启「允许后台运行」与「允许自启动」',
      ],
    );
  }

  if (m == 'vivo' || b == 'vivo' || b == 'iqoo') {
    return const OemWhitelistGuide(
      needsGuide: true,
      oemKey: 'vivo',
      title: '开启后台运行,避免消息丢失',
      reason: _kOemReason,
      steps: [
        '进入「设置 → 电池 → 后台耗电管理」',
        '找到「Bot助手」,允许「后台高耗电」',
      ],
    );
  }

  return OemWhitelistGuide.none;
}
