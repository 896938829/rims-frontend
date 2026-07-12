final class CreateDocumentRequest {
  const CreateDocumentRequest({
    required this.docType,
    required this.typeLabel,
    this.requestId = '',
    this.lines = const [],
    int productId = 0,
    String productName = '',
    int quantity = 0,
    this.toWarehouseId,
    this.refDocId,
    int? actualQuantity,
    int? nonStdInventoryId,
    double? retailPrice,
    this.remark = '',
  }) : _legacyProductId = productId,
       _legacyProductName = productName,
       _legacyQuantity = quantity,
       _legacyActualQuantity = actualQuantity,
       _legacyNonStdInventoryId = nonStdInventoryId,
       _legacyRetailPrice = retailPrice;

  final int docType;
  final String typeLabel;
  final String requestId;
  final List<CreateDocumentLineRequest> lines;
  final int _legacyProductId;
  final String _legacyProductName;
  final int _legacyQuantity;
  final int? toWarehouseId;
  final int? refDocId;
  final int? _legacyActualQuantity;
  final int? _legacyNonStdInventoryId;
  final double? _legacyRetailPrice;
  final String remark;

  List<CreateDocumentLineRequest> get effectiveLines => lines.isNotEmpty
      ? lines
      : [
          CreateDocumentLineRequest(
            productId: _legacyProductId,
            productName: _legacyProductName,
            quantity: _legacyQuantity,
            actualQuantity: _legacyActualQuantity,
            nonStandardInventoryId: _legacyNonStdInventoryId,
            retailPrice: _legacyRetailPrice,
          ),
        ];

  int get productId => effectiveLines.first.productId;
  String get productName => effectiveLines.first.productName;
  int get quantity => effectiveLines.first.quantity;
  int? get actualQuantity => effectiveLines.first.actualQuantity;
  int? get nonStdInventoryId => effectiveLines.first.nonStandardInventoryId;
  double? get retailPrice => effectiveLines.first.retailPrice;
}

final class CreateDocumentLineRequest {
  const CreateDocumentLineRequest({
    required this.productId,
    required this.productName,
    required this.quantity,
    this.actualQuantity,
    this.nonStandardInventoryId,
    this.retailPrice,
  });

  final int productId;
  final String productName;
  final int quantity;
  final int? actualQuantity;
  final int? nonStandardInventoryId;
  final double? retailPrice;
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
    this.remark = '',
    this.createdAt = '',
  });

  final int id;
  final int docType;
  final String title;
  final String number;
  final String status;
  final String productName;
  final int quantity;
  final String remark;
  final String createdAt;
}

final class DocumentLine {
  const DocumentLine({
    required this.id,
    required this.productId,
    required this.nonStandardInventoryId,
    required this.productCode,
    required this.productName,
    required this.quantity,
    required this.unit,
    required this.costPrice,
    required this.retailPrice,
    required this.systemQuantity,
    required this.actualQuantity,
    required this.differenceQuantity,
    required this.remark,
  });

  final int id;
  final int productId;
  final int nonStandardInventoryId;
  final String productCode;
  final String productName;
  final int quantity;
  final String unit;
  final double costPrice;
  final double retailPrice;
  final int systemQuantity;
  final int actualQuantity;
  final int differenceQuantity;
  final String remark;
}

final class DocumentDetail {
  DocumentDetail({required this.record, required List<DocumentLine> lines})
    : lines = List.unmodifiable(lines);

  final DocumentRecord record;
  final List<DocumentLine> lines;
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
