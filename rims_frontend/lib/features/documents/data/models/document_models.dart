import '../../domain/entities/document_data.dart';

final class DocumentRecordModel {
  const DocumentRecordModel({
    required this.id,
    required this.docType,
    required this.title,
    required this.number,
    required this.status,
    required this.productName,
    required this.quantity,
    required this.remark,
    required this.createdAt,
  });

  factory DocumentRecordModel.fromJson(Map<dynamic, dynamic> json) {
    final docType = _readInt(json, const ['docType', 'type']) ?? 0;
    final firstLine = _readFirstLine(json);
    return DocumentRecordModel(
      id: _readInt(json, const ['id', 'documentId']) ?? 0,
      docType: docType,
      title:
          _readString(json, const [
            'title',
            'typeLabel',
            'typeName',
            'docTypeName',
            'documentTypeName',
          ]) ??
          '',
      number:
          _readString(json, const [
            'number',
            'docNo',
            'documentNo',
            'billNo',
            'code',
          ]) ??
          '',
      status: _readDocumentStatus(json, docType),
      productName:
          _readString(json, const ['productName', 'goodsName', 'skuName']) ??
          _readString(firstLine, const [
            'productName',
            'goodsName',
            'skuName',
          ]) ??
          '',
      quantity:
          _readInt(json, const ['quantity', 'qty', 'count']) ??
          _readInt(firstLine, const [
            'quantity',
            'qty',
            'count',
            'actualQty',
          ]) ??
          0,
      remark: _readString(json, const ['remark', 'notes', 'description']) ?? '',
      createdAt:
          _readString(json, const [
            'createdAt',
            'created_at',
            'createdTime',
            'createdDate',
            'documentDate',
            'docDate',
            'billDate',
          ]) ??
          '',
    );
  }

  final int id;
  final int docType;
  final String title;
  final String number;
  final String status;
  final String productName;
  final int quantity;
  final String remark;
  final String createdAt;

  DocumentRecord toEntity() {
    return DocumentRecord(
      id: id,
      docType: docType,
      title: title,
      number: number,
      status: status,
      productName: productName,
      quantity: quantity,
      remark: remark,
      createdAt: createdAt,
    );
  }
}

final class DocumentDetailModel {
  DocumentDetailModel({
    required this.record,
    required List<DocumentLineModel> lines,
  }) : lines = List.unmodifiable(lines);

  factory DocumentDetailModel.fromJson(Map<dynamic, dynamic> json) {
    final rawLines = json['lines'];
    if (rawLines is! List<dynamic>) {
      throw const FormatException('Document detail lines must be a list.');
    }
    final lines = <DocumentLineModel>[];
    for (final rawLine in rawLines) {
      if (rawLine is! Map<dynamic, dynamic>) {
        throw const FormatException('Every document line must be an object.');
      }
      lines.add(DocumentLineModel.fromJson(rawLine));
    }
    final record = DocumentRecordModel.fromJson(json);
    if (record.id <= 0 || record.number.isEmpty || record.docType <= 0) {
      throw const FormatException('Invalid document detail header.');
    }
    return DocumentDetailModel(record: record, lines: lines);
  }

  final DocumentRecordModel record;
  final List<DocumentLineModel> lines;

  DocumentDetail toEntity() => DocumentDetail(
    record: record.toEntity(),
    lines: lines.map((line) => line.toEntity()).toList(growable: false),
  );
}

final class DocumentLineModel {
  const DocumentLineModel({
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

  factory DocumentLineModel.fromJson(Map<dynamic, dynamic> json) {
    final id = _strictInt(json, 'id');
    final productId = _strictOptionalInt(json, 'productId');
    final nonStandardId = _strictOptionalInt(json, 'nonStdInvId');
    if (id <= 0 || (productId <= 0 && nonStandardId <= 0)) {
      throw const FormatException('Invalid document line identity.');
    }
    return DocumentLineModel(
      id: id,
      productId: productId,
      nonStandardInventoryId: nonStandardId,
      productCode: _strictString(json, 'productCode'),
      productName: _strictString(json, 'productName'),
      quantity: _strictInt(json, 'quantity'),
      unit: _strictString(json, 'unit'),
      costPrice: _strictOptionalDouble(json, 'costPrice'),
      retailPrice: _strictOptionalDouble(json, 'retailPrice'),
      systemQuantity: _strictOptionalInt(json, 'systemQty'),
      actualQuantity: _strictOptionalInt(json, 'actualQty'),
      differenceQuantity: _strictOptionalInt(json, 'diffQty'),
      remark: _strictString(json, 'remark'),
    );
  }

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

  DocumentLine toEntity() => DocumentLine(
    id: id,
    productId: productId,
    nonStandardInventoryId: nonStandardInventoryId,
    productCode: productCode,
    productName: productName,
    quantity: quantity,
    unit: unit,
    costPrice: costPrice,
    retailPrice: retailPrice,
    systemQuantity: systemQuantity,
    actualQuantity: actualQuantity,
    differenceQuantity: differenceQuantity,
    remark: remark,
  );
}

final class TransactionRecordModel {
  const TransactionRecordModel({
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

  factory TransactionRecordModel.fromJson(Map<dynamic, dynamic> json) {
    return TransactionRecordModel(
      id: _readInt(json, const ['id', 'transactionId']) ?? 0,
      warehouseId: _readInt(json, const ['warehouseId']) ?? 0,
      productId: _readInt(json, const ['productId']) ?? 0,
      docId: _readInt(json, const ['docId', 'documentId']) ?? 0,
      docNo: _readString(json, const ['docNo', 'documentNo', 'number']) ?? '',
      docType: _readInt(json, const ['docType']) ?? 0,
      docTypeName: _readString(json, const ['docTypeName', 'typeName']) ?? '',
      direction: _readInt(json, const ['direction']) ?? 0,
      quantity: _readInt(json, const ['quantity', 'qty']) ?? 0,
      beforeQty: _readInt(json, const ['beforeQty']) ?? 0,
      afterQty: _readInt(json, const ['afterQty']) ?? 0,
      operatorId: _readInt(json, const ['operatorId']) ?? 0,
      operatedAt: _readString(json, const ['operatedAt']) ?? '',
      createdAt: _readString(json, const ['createdAt']) ?? '',
    );
  }

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

  TransactionRecord toEntity() {
    return TransactionRecord(
      id: id,
      warehouseId: warehouseId,
      productId: productId,
      docId: docId,
      docNo: docNo,
      docType: docType,
      docTypeName: docTypeName,
      direction: direction,
      quantity: quantity,
      beforeQty: beforeQty,
      afterQty: afterQty,
      operatorId: operatorId,
      operatedAt: operatedAt,
      createdAt: createdAt,
    );
  }
}

Map<dynamic, dynamic> _readFirstLine(Map<dynamic, dynamic> json) {
  final rawList = switch (json) {
    {'lines': final List<dynamic> list} => list,
    {'items': final List<dynamic> list} => list,
    {'details': final List<dynamic> list} => list,
    _ => const <dynamic>[],
  };

  for (final line in rawList) {
    if (line is Map<dynamic, dynamic>) {
      return line;
    }
  }

  return const {};
}

String _readDocumentStatus(Map<dynamic, dynamic> json, int docType) {
  final label = _readString(json, const ['statusLabel', 'statusName']);
  if (label != null) {
    return label;
  }

  final status = _readInt(json, const ['status']);
  if (status == null) {
    return _readString(json, const ['status']) ?? '';
  }

  if (docType == 5) {
    return switch (status) {
      1 => '盘点中',
      2 => '差异已确认',
      3 => '已结转',
      _ => status.toString(),
    };
  }

  return switch (status) {
    1 => '草稿',
    2 => '已完成',
    _ => status.toString(),
  };
}

int? _readInt(Map<dynamic, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    if (value is String) {
      return int.tryParse(value) ?? double.tryParse(value)?.round();
    }
  }

  return null;
}

String? _readString(Map<dynamic, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
    if (value is num) {
      return value.toString();
    }
  }

  return null;
}

int _strictInt(Map<dynamic, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.truncate()) {
    return value.toInt();
  }
  throw FormatException('Document line $key must be an integer.');
}

int _strictOptionalInt(Map<dynamic, dynamic> json, String key) {
  if (!json.containsKey(key) || json[key] == null) return 0;
  return _strictInt(json, key);
}

double _strictOptionalDouble(Map<dynamic, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return 0;
  if (value is num && value.isFinite) return value.toDouble();
  throw FormatException('Document line $key must be numeric.');
}

String _strictString(Map<dynamic, dynamic> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('Document line $key must be a string.');
}
