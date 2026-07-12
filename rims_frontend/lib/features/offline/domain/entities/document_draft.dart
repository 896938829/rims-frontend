final class DocumentDraft {
  const DocumentDraft({
    required this.id,
    required this.accountId,
    required this.warehouseId,
    required this.payload,
    required this.createdAt,
    required this.updatedAt,
    this.version = 1,
  });

  final String id;
  final String accountId;
  final int warehouseId;
  final Map<String, Object?> payload;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int version;
}
