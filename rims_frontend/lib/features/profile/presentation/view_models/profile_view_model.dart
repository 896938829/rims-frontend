final class ProfileViewModel {
  const ProfileViewModel();

  String get userName => '张三';
  String get workId => 'U10086';
  String get roleName => '普通用户';
  String get warehouseName => '上海仓';

  List<String> get apiGuards => const [
    'JWT',
    'X-Warehouse-ID',
    'Permission',
    'Idempotency-Key',
    'traceId',
  ];

  List<String> get backendModules => const [
    'user',
    'warehouse',
    'product',
    'document',
    'report',
    'file',
    'audit',
  ];

  List<PermissionGroup> get permissionGroups => const [
    PermissionGroup(
      roleName: '管理员',
      summary: '拥有系统配置、权限分配与全仓业务管理能力',
      capabilities: ['用户管理', '角色授权', '仓库配置', '单据审核', '报表导出'],
    ),
    PermissionGroup(
      roleName: '普通用户',
      summary: '可处理日常库存、单据与个人工作台信息',
      capabilities: ['库存查询', '扫码入库', '单据创建', '报表查看', '个人资料'],
    ),
  ];
}

final class PermissionGroup {
  const PermissionGroup({
    required this.roleName,
    required this.summary,
    required this.capabilities,
  });

  final String roleName;
  final String summary;
  final List<String> capabilities;
}
