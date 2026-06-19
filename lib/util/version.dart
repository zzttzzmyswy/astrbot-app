// lib/util/version.dart

/// 语义版本比较,容忍 `v` 前缀与不同段数(1.0 vs 1.0.0)。
/// 返回:-1 (a<b), 0 (a==b), 1 (a>b)。非数字段按字符串回退比较。
int compareVersions(String a, String b) {
  final pa = _stripV(a).split(RegExp(r'[.+-]'));
  final pb = _stripV(b).split(RegExp(r'[.+-]'));
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (int i = 0; i < n; i++) {
    final sa = i < pa.length ? pa[i] : '0';
    final sb = i < pb.length ? pb[i] : '0';
    final na = int.tryParse(sa);
    final nb = int.tryParse(sb);
    if (na != null && nb != null) {
      if (na != nb) return na < nb ? -1 : 1;
    } else {
      if (sa != sb) return sa.compareTo(sb) < 0 ? -1 : 1;
    }
  }
  return 0;
}

String _stripV(String v) {
  final s = v.trim();
  return s.startsWith('v') || s.startsWith('V') ? s.substring(1) : s;
}
