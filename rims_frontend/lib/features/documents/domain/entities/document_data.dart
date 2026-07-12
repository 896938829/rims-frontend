final class CreateDocumentRequest {
  const CreateDocumentRequest({
    required this.docType,
    required this.typeLabel,
    required this.productId,
    required this.productName,
    required this.quantity,
    this.toWarehouseId,
    this.refDocId,
    this.actualQuantity,
    this.nonStdInventoryId,
    this.retailPrice,
    this.remark = '',
  });

  final int docType;
  final String typeLabel;
  final int productId;
  final String productName;
  final int quantity;
  final int? toWarehouseId;
  final int? refDocId;
  final int? actualQuantity;
  final int? nonStdInventoryId;
  final double? retailPrice;
  final String remark;
}

final class DocumentRecord {
  const DocumentRecord({
    required this.id,
    required this.docType,
    required this.title,
    required this.number,
    required this.status,
    this.productName = '',
    this.quantity = 0,
    this.createdAt = '',
  });

  final int id;
  final int docType;
  final String title;
  final String number;
  final String status;
  final String productName;
  final int quantity;
  final String createdAt;
}

final class TransactionRecord {
  const TransactionRecord({
    required this.id,
    required this.warehouseId,
    required this.productId,
    required this.docId,
    required this.docNo,
    required this.docType,
    required this.docTypeName,
    required this.direction,
    required this.quantity,
    required this.beforeQty,
    required this.afterQty,
    required this.operatorId,
    required this.operatedAt,
    required this.createdAt,
  });

  final int id;
  final int warehouseId;
  final int productId;
  final int docId;
  final String docNo;
  final int docType;
  final String docTypeName;
  final int direction;
  final int quantity;
  final int beforeQty;
  final int afterQty;
  final int operatorId;
  final String operatedAt;
  final String createdAt;

  String get directionLabel {
    return switch (direction) {
      1 => '入库',
      -1 => '出库',
      _ => '调整',
    };
  }
}
