final class CreateDocumentRequest {
  const CreateDocumentRequest({
    required this.typeCode,
    required this.typeLabel,
    required this.productName,
    required this.quantity,
  });

  final String typeCode;
  final String typeLabel;
  final String productName;
  final int quantity;
}

final class DocumentRecord {
  const DocumentRecord({
    required this.id,
    required this.title,
    required this.number,
    required this.status,
    this.productName = '',
    this.quantity = 0,
  });

  final int id;
  final String title;
  final String number;
  final String status;
  final String productName;
  final int quantity;
}
