import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/widgets/rims_status_chip.dart';
import 'package:rims_frontend/features/documents/presentation/widgets/document_status_kind.dart';

void main() {
  test('documentStatusKind maps actionable document statuses', () {
    expect(documentStatusKind('草稿'), RimsStatusKind.warning);
    expect(documentStatusKind('待提交'), RimsStatusKind.warning);
    expect(documentStatusKind('盘点中'), RimsStatusKind.warning);
    expect(documentStatusKind('差异已确认'), RimsStatusKind.pending);
    expect(documentStatusKind('已完成'), RimsStatusKind.success);
    expect(documentStatusKind('已结转'), RimsStatusKind.success);
    expect(documentStatusKind('已取消'), RimsStatusKind.error);
    expect(documentStatusKind('未知'), RimsStatusKind.info);
  });
}
