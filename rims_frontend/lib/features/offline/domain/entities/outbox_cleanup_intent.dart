import 'immutable_snapshot.dart';

final class OutboxCleanupRequest {
  OutboxCleanupRequest({
    this.draftId,
    List<String> attachmentRequestIds = const [],
  }) : attachmentRequestIds = immutableListSnapshot(attachmentRequestIds);

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
  }) : attachmentRequestIds = immutableListSnapshot(attachmentRequestIds);

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
