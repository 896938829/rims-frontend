import 'immutable_snapshot.dart';
import 'outbox_operation_output.dart';

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
  documentReference('document_reference'),
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
  OutboxOperation({
    required this.operationId,
    required this.idempotencyKey,
    required this.accountId,
    required this.warehouseId,
    required this.kind,
    required Map<String, Object?> payload,
    required this.state,
    required this.createdAt,
    DateTime? updatedAt,
    this.confirmedAt,
    this.nextAttemptAt,
    this.attemptCount = 0,
    this.lastFailureCode,
    this.replacementOf,
    this.reviewStamp,
    this.requiresStatusProbe = false,
    this.syncingStartedAt,
    this.output,
  }) : payload = immutableMapSnapshot(payload),
       updatedAt = updatedAt ?? createdAt;

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
  final String? replacementOf;
  final String? reviewStamp;
  final bool requiresStatusProbe;
  final DateTime? syncingStartedAt;
  final OutboxOperationOutput? output;

  bool get isConfirmed => confirmedAt != null;

  OutboxOperation copyWith({
    OutboxState? state,
    DateTime? updatedAt,
    DateTime? nextAttemptAt,
    bool clearNextAttemptAt = false,
    int? attemptCount,
    String? lastFailureCode,
    String? replacementOf,
    DateTime? confirmedAt,
    String? reviewStamp,
    bool clearReview = false,
    bool? requiresStatusProbe,
    DateTime? syncingStartedAt,
    bool clearSyncingStartedAt = false,
    OutboxOperationOutput? output,
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
      confirmedAt: clearReview ? null : confirmedAt ?? this.confirmedAt,
      nextAttemptAt: clearNextAttemptAt
          ? null
          : nextAttemptAt ?? this.nextAttemptAt,
      attemptCount: attemptCount ?? this.attemptCount,
      lastFailureCode: lastFailureCode ?? this.lastFailureCode,
      replacementOf: replacementOf ?? this.replacementOf,
      reviewStamp: clearReview ? null : reviewStamp ?? this.reviewStamp,
      requiresStatusProbe: requiresStatusProbe ?? this.requiresStatusProbe,
      syncingStartedAt: clearSyncingStartedAt
          ? null
          : syncingStartedAt ?? this.syncingStartedAt,
      output: output ?? this.output,
    );
  }
}
