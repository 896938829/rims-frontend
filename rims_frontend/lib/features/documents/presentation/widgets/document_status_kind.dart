import '../../../../core/widgets/rims_status_chip.dart';

RimsStatusKind documentStatusKind(String status) {
  switch (status) {
    case '已完成':
    case '已结转':
      return RimsStatusKind.success;
    case '草稿':
    case '待提交':
    case '待确认':
    case '盘点中':
      return RimsStatusKind.warning;
    case '差异已确认':
    case '待结转':
      return RimsStatusKind.pending;
    case '已取消':
      return RimsStatusKind.error;
    default:
      return RimsStatusKind.info;
  }
}
