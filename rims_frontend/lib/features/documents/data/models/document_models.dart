import '../../domain/entities/document_data.dart';

final class DocumentRecordModel {
  const DocumentRecordModel({
    required this.id,
    required this.title,
    required this.number,
    required this.status,
    required this.productName,
    required this.quantity,
  });

  factory DocumentRecordModel.fromJson(Map<dynamic, dynamic> json) {
    return DocumentRecordModel(
      id: _readInt(json, const ['id', 'documentId']) ?? 0,
      title:
          _readString(json, const [
            'title',
            'typeLabel',
            'typeName',
            'documentTypeName',
          ]) ??
          '',
      number:
          _readString(json, const ['number', 'documentNo', 'billNo', 'code']) ??
          '',
      status:
          _readString(json, const ['statusLabel', 'statusName', 'status']) ??
          '',
      productName:
          _readString(json, const ['productName', 'goodsName', 'skuName']) ??
          '',
      quantity: _readInt(json, const ['quantity', 'qty', 'count']) ?? 0,
    );
  }

  final int id;
  final String title;
  final String number;
  final String status;
  final String productName;
  final int quantity;

  DocumentRecord toEntity() {
    return DocumentRecord(
      id: id,
      title: title,
      number: number,
      status: status,
      productName: productName,
      quantity: quantity,
    );
  }
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
