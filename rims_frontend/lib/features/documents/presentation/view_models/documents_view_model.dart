import '../../../../core/resources/app_icons.dart';

final class DocumentAction {
  const DocumentAction({required this.label, required this.iconPath});

  final String label;
  final String iconPath;
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

final class DocumentsViewModel {
  const DocumentsViewModel();

  List<DocumentAction> get actions => const [
    DocumentAction(label: '销售出库', iconPath: AppIcons.actionInbound),
    DocumentAction(label: '采购入库', iconPath: AppIcons.actionReport),
    DocumentAction(label: '调拨单', iconPath: AppIcons.actionTransfer),
    DocumentAction(label: '盘点单', iconPath: AppIcons.actionStocktake),
    DocumentAction(label: '退货入库', iconPath: AppIcons.actionReturn),
    DocumentAction(label: '转标准', iconPath: AppIcons.actionScan),
  ];

  List<String> get flowSteps => const ['创建', '确认', '提交', '完成'];

  List<RecentDocument> get recentDocuments => const [
    RecentDocument(title: '销售出库', number: 'SO-20260616-001', status: '已完成'),
    RecentDocument(title: '采购入库', number: 'PI-20260616-004', status: '待提交'),
    RecentDocument(title: '退货入库', number: 'RT-20260615-018', status: '已取消'),
  ];
}
