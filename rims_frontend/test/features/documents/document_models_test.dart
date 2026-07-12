import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/documents/data/models/document_models.dart';

void main() {
  test('DocumentRecordModel parses backend document fields', () {
    final model = DocumentRecordModel.fromJson(const {
      'id': 136,
      'docNo': 'XS20260417035',
      'docType': 2,
      'docTypeName': '销售单',
      'statusName': '已完成',
      'remark': 'M9-E2E:run-42:sales',
      'createdAt': '2026-07-02T10:15:00Z',
    });

    expect(model.id, 136);
    expect(model.docType, 2);
    expect(model.title, '销售单');
    expect(model.number, 'XS20260417035');
    expect(model.status, '已完成');
    expect(model.remark, 'M9-E2E:run-42:sales');
    expect(model.createdAt, '2026-07-02T10:15:00Z');
    expect(model.toEntity().remark, 'M9-E2E:run-42:sales');
    expect(model.toEntity().createdAt, '2026-07-02T10:15:00Z');
  });

  test('DocumentRecordModel maps numeric regular document status', () {
    final draft = DocumentRecordModel.fromJson(const {
      'id': 7,
      'docNo': 'XS20260706001',
      'docType': 2,
      'docTypeName': '销售单',
      'status': 1,
    });
    final completed = DocumentRecordModel.fromJson(const {
      'id': 8,
      'docNo': 'RK20260706001',
      'docType': 1,
      'docTypeName': '入库单',
      'status': 2,
    });

    expect(draft.status, '草稿');
    expect(completed.status, '已完成');
  });

  test('DocumentRecordModel maps numeric stocktake status', () {
    final counting = DocumentRecordModel.fromJson(const {
      'id': 9,
      'docNo': 'PD20260706001',
      'docType': 5,
      'docTypeName': '盘点单',
      'status': 1,
    });
    final confirmed = DocumentRecordModel.fromJson(const {
      'id': 10,
      'docNo': 'PD20260706002',
      'docType': 5,
      'docTypeName': '盘点单',
      'status': 2,
    });
    final settled = DocumentRecordModel.fromJson(const {
      'id': 11,
      'docNo': 'PD20260706003',
      'docType': 5,
      'docTypeName': '盘点单',
      'status': 3,
    });

    expect(counting.status, '盘点中');
    expect(confirmed.status, '差异已确认');
    expect(settled.status, '已结转');
  });

  test('DocumentRecordModel reads product summary from first line', () {
    final model = DocumentRecordModel.fromJson(const {
      'id': 12,
      'docNo': 'XS20260706004',
      'docType': 2,
      'docTypeName': '销售单',
      'status': 1,
      'lines': [
        {'productName': '矿泉水 550ml', 'quantity': 3},
      ],
    });

    expect(model.productName, '矿泉水 550ml');
    expect(model.quantity, 3);
    expect(model.toEntity().productName, '矿泉水 550ml');
    expect(model.toEntity().quantity, 3);
  });

  test('TransactionRecordModel parses backend transaction fields', () {
    final model = TransactionRecordModel.fromJson({
      'id': 21,
      'warehouseId': 1,
      'productId': 10,
      'docId': 7,
      'docNo': 'XS20260627001',
      'docType': 2,
      'docTypeName': '销售单',
      'direction': -1,
      'quantity': 3,
      'beforeQty': 12,
      'afterQty': 9,
      'operatorId': 5,
      'operatedAt': '2026-06-27T10:30:00Z',
      'createdAt': '2026-06-27T10:30:00Z',
    });

    final record = model.toEntity();

    expect(record.id, 21);
    expect(record.productId, 10);
    expect(record.docNo, 'XS20260627001');
    expect(record.docTypeName, '销售单');
    expect(record.direction, -1);
    expect(record.directionLabel, '出库');
    expect(record.quantity, 3);
    expect(record.beforeQty, 12);
    expect(record.afterQty, 9);
    expect(record.operatedAt, '2026-06-27T10:30:00Z');
  });
}
