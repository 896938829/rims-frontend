import '../entities/outbox_operation.dart';

abstract final class AttachmentStagingProtection {
  static Set<String> requestIdsFor(Iterable<OutboxOperation> operations) {
    final protected = <String>{};
    for (final operation in operations) {
      if (!_isRecoverable(operation.state)) continue;
      _collectRequestIds(operation.payload, protected);
    }
    return Set.unmodifiable(protected);
  }

  static bool _isRecoverable(OutboxState state) =>
      state == OutboxState.queued ||
      state == OutboxState.syncing ||
      state == OutboxState.retryableFailure ||
      state == OutboxState.conflict;

  static void _collectRequestIds(
    Map<String, Object?> payload,
    Set<String> target,
  ) {
    final requestId = payload['requestId'];
    if (requestId is String && requestId.isNotEmpty) target.add(requestId);

    final attachmentRequestIds = payload['attachmentRequestIds'];
    if (attachmentRequestIds is List) {
      target.addAll(attachmentRequestIds.whereType<String>());
    }

    final cleanup = payload['cleanup'];
    if (cleanup is Map) {
      final cleanupRequestIds = cleanup['attachmentRequestIds'];
      if (cleanupRequestIds is List) {
        target.addAll(cleanupRequestIds.whereType<String>());
      }
    }
  }
}
