final class AppUser {
  const AppUser({
    required this.id,
    required this.username,
    required this.realName,
    required this.roleCode,
    required this.roleName,
  });

  final int id;
  final String username;
  final String realName;
  final String roleCode;
  final String roleName;

  bool get isAdmin => roleCode.trim().toLowerCase() == 'admin';
}
