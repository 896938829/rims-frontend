final class OutboxCleanupRequest {
  const OutboxCleanupRequest({
    this.draftId,
    this.attachmentRequestIds = const [],
  });

  final String? draftId;
  final List<String> attachmentRequestIds;
}

final class OutboxCleanupIntent {
  OutboxCleanupIntent({
    required this.operationId,
    required this.accountId,
    required this.warehouseId,
    required this.createdAt,
    required this.updatedAt,
    this.draftId,
    List<String> attachmentRequestIds = const [],
    this.attemptCount = 0,
    this.lastFailure,
  }) : attachmentRequestIds = List.unmodifiable(attachmentRequestIds);

  final String operationId;
  final String accountId;
  final int warehouseId;
  final String? draftId;
  final List<String> attachmentRequestIds;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int attemptCount;
  final String? lastFailure;
}
