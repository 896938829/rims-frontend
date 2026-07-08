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
      createdAt: createdAt,
    );
  }
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
