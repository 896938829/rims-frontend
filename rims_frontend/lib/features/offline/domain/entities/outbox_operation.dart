enum OutboxState {
  queued('queued'),
  syncing('syncing'),
  succeeded('succeeded'),
  retryableFailure('retryable_failure'),
  conflict('conflict'),
  permanentFailure('permanent_failure'),
  cancelled('cancelled');

  const OutboxState(this.wireValue);

  final String wireValue;
}

enum OutboxOperationKind {
  attachmentUpload('attachment_upload'),
  documentCreate('document_create'),
  documentComplete('document_complete'),
  stocktakeConfirm('stocktake_confirm'),
  stocktakeSettle('stocktake_settle');

  const OutboxOperationKind(this.wireValue);

  final String wireValue;
}

bool isOutboxTransitionAllowed(OutboxState current, OutboxState next) {
  return switch (current) {
    OutboxState.queued =>
      next == OutboxState.syncing || next == OutboxState.cancelled,
    OutboxState.syncing =>
      next == OutboxState.succeeded ||
          next == OutboxState.retryableFailure ||
          next == OutboxState.conflict ||
          next == OutboxState.permanentFailure ||
          next == OutboxState.cancelled,
    OutboxState.retryableFailure =>
      next == OutboxState.syncing || next == OutboxState.cancelled,
    OutboxState.conflict => false,
    OutboxState.succeeded ||
    OutboxState.permanentFailure ||
    OutboxState.cancelled => false,
  };
}

final class OutboxOperation {
  const OutboxOperation({
    required this.operationId,
    required this.idempotencyKey,
    required this.accountId,
    required this.warehouseId,
    required this.kind,
    required this.payload,
    required this.state,
    required this.createdAt,
    DateTime? updatedAt,
    this.confirmedAt,
    this.nextAttemptAt,
    this.attemptCount = 0,
    this.lastFailureCode,
  }) : updatedAt = updatedAt ?? createdAt;

  final String operationId;
  final String idempotencyKey;
  final String accountId;
  final int warehouseId;
  final OutboxOperationKind kind;
  final Map<String, Object?> payload;
  final OutboxState state;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? confirmedAt;
  final DateTime? nextAttemptAt;
  final int attemptCount;
  final String? lastFailureCode;

  bool get isConfirmed => confirmedAt != null;

  OutboxOperation copyWith({
    OutboxState? state,
    DateTime? updatedAt,
    DateTime? nextAttemptAt,
    bool clearNextAttemptAt = false,
    int? attemptCount,
    String? lastFailureCode,
  }) {
    return OutboxOperation(
      operationId: operationId,
      idempotencyKey: idempotencyKey,
      accountId: accountId,
      warehouseId: warehouseId,
      kind: kind,
      payload: payload,
      state: state ?? this.state,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      confirmedAt: confirmedAt,
      nextAttemptAt: clearNextAttemptAt
          ? null
          : nextAttemptAt ?? this.nextAttemptAt,
      attemptCount: attemptCount ?? this.attemptCount,
      lastFailureCode: lastFailureCode ?? this.lastFailureCode,
    );
  }
}
