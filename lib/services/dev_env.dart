/// API Gateway base URL. Overridden via --dart-define=API_BASE_URL=... for
/// local dev (http://localhost:8000) — defaults to production otherwise.
const String kApiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod',
);

/// Member portal base URL. Override with --dart-define=MEMBER_PORTAL_URL=...
const String kMemberPortalUrl = String.fromEnvironment(
  'MEMBER_PORTAL_URL',
  defaultValue: 'https://member.kafayiti.com',
);

/// Empty in prod builds. Dev builds (devmember.kafayiti.com,
/// devadmin.kafayiti.com) pass --dart-define=API_ENV_SUFFIX=-dev so member
/// and policy reads/writes route to the isolated dev DynamoDB tables
/// (kopera-member-dev, kopera-life-insurance-dev) instead of production data.
const String kApiEnvSuffix =
    String.fromEnvironment('API_ENV_SUFFIX', defaultValue: '');

/// Rewrites a path's first segment ("members"/"member"/"prospects") to its
/// "-dev" variant in dev builds. No-op in prod builds since [kApiEnvSuffix] is empty.
String devPath(String path) {
  if (kApiEnvSuffix.isEmpty) return path;
  if (path.startsWith('/members/') || path == '/members') {
    return '/members$kApiEnvSuffix${path.substring('/members'.length)}';
  }
  if (path.startsWith('/member/') || path == '/member') {
    return '/member$kApiEnvSuffix${path.substring('/member'.length)}';
  }
  if (path.startsWith('/prospects/') || path == '/prospects') {
    return '/prospects$kApiEnvSuffix${path.substring('/prospects'.length)}';
  }
  if (path.startsWith('/payments/') || path == '/payments') {
    return '/payments$kApiEnvSuffix${path.substring('/payments'.length)}';
  }
  return path;
}
