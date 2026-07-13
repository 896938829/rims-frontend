final class AppUser {
  const AppUser({
    required this.id,
    required this.username,
    required this.realName,
    required this.roleCode,
    required this.roleName,
    this.permissionCodes = const {},
  });

  final int id;
  final String username;
  final String realName;
  final String roleCode;
  final String roleName;
  final Set<String> permissionCodes;

  bool get isAdmin => roleCode.trim().toLowerCase() == 'admin';
}
