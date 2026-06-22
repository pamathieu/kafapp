/// Empty in prod builds. Dev builds (devmember.kafayiti.com,
/// devadmin.kafayiti.com) pass --dart-define=API_ENV_SUFFIX=-dev so member
/// and policy reads/writes route to the isolated dev DynamoDB tables
/// (kopera-member-dev, kopera-life-insurance-dev) instead of production data.
const String kApiEnvSuffix =
    String.fromEnvironment('API_ENV_SUFFIX', defaultValue: '');

/// Rewrites a path's first segment ("members"/"member") to its "-dev"
/// variant in dev builds. No-op in prod builds since [kApiEnvSuffix] is empty.
String devPath(String path) {
  if (kApiEnvSuffix.isEmpty) return path;
  if (path.startsWith('/members/') || path == '/members') {
    return '/members$kApiEnvSuffix${path.substring('/members'.length)}';
  }
  if (path.startsWith('/member/') || path == '/member') {
    return '/member$kApiEnvSuffix${path.substring('/member'.length)}';
  }
  return path;
}
