final class DeviceSession {
  const DeviceSession({
    required this.id,
    required this.deviceLabel,
    required this.platform,
    required this.userAgentFamily,
    required this.createdAt,
    required this.lastUsedAt,
    required this.expiresAt,
    required this.current,
    this.revokedAt,
  });

  final String id;
  final String deviceLabel;
  final String platform;
  final String userAgentFamily;
  final DateTime createdAt;
  final DateTime lastUsedAt;
  final DateTime expiresAt;
  final DateTime? revokedAt;
  final bool current;
}
