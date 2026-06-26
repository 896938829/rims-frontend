import '../../../../core/resources/app_icons.dart';
import '../../../auth/domain/entities/app_user.dart';
import '../../../auth/domain/entities/warehouse.dart';

final class HomeMetric {
  const HomeMetric({
    required this.label,
    required this.value,
    required this.delta,
  });

  final String label;
  final String value;
  final String delta;
}

final class HomeQuickAction {
  const HomeQuickAction({required this.label, required this.icon});

  final String label;
  final String icon;
}

final class InventoryWarning {
  const InventoryWarning({
    required this.label,
    required this.count,
    required this.level,
  });

  final String label;
  final int count;
  final String level;
}

final class RecentDocument {
  const RecentDocument({
    required this.title,
    required this.number,
    required this.status,
  });

  final String title;
  final String number;
  final String status;
}

final class HomeViewModel {
  const HomeViewModel({this.user, this.warehouse});

  final AppUser? user;
  final Warehouse? warehouse;

  String get warehouseName => warehouse?.name ?? '未选择仓库';
  String get greeting {
    final name = user?.realName.isNotEmpty == true
        ? user!.realName
        : user?.username ?? '未登录用户';
    return 'Good morning, $name';
  }

  List<HomeMetric> get metrics => const [
    HomeMetric(label: '商品数', value: '1,268', delta: '+12%'),
    HomeMetric(label: '库存总量', value: '18,732', delta: '+8%'),
    HomeMetric(label: '预警数量', value: '23', delta: '+15%'),
  ];

  List<HomeQuickAction> get quickActions => const [
    HomeQuickAction(label: '扫码销售', icon: AppIcons.actionScan),
    HomeQuickAction(label: '退货', icon: AppIcons.actionReturn),
    HomeQuickAction(label: '入库', icon: AppIcons.actionInbound),
    HomeQuickAction(label: '调拨', icon: AppIcons.actionTransfer),
  ];

  List<InventoryWarning> get warnings => const [
    InventoryWarning(label: '低库存', count: 23, level: 'warning'),
    InventoryWarning(label: '超储商品', count: 15, level: 'warning'),
    InventoryWarning(label: '滞销预警', count: 18, level: 'info'),
  ];

  List<RecentDocument> get recentDocuments => const [
    RecentDocument(title: '销售出库单', number: 'SO-20240518-0012', status: '已完成'),
    RecentDocument(title: '采购入库单', number: 'PO-20240518-0008', status: '待确认'),
    RecentDocument(title: '库存盘点单', number: 'ST-20240517-0003', status: '待结转'),
  ];
}
