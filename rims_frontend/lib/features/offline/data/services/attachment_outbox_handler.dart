import '../../../../core/events/app_event_bus.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../attachments/data/datasources/attachments_remote_datasource.dart';
import '../../../attachments/domain/entities/attachment.dart';
import '../../../attachments/domain/services/attachment_staging_store.dart';
import '../../domain/entities/outbox_operation.dart';
import '../../domain/entities/outbox_graph.dart';
import '../../domain/entities/outbox_cleanup_intent.dart';
import '../../domain/repositories/document_draft_repository.dart';
import '../../domain/services/outbox_executor.dart';

final class AttachmentOutboxHandler implements OutboxOperationHandler {
  const AttachmentOutboxHandler({
    required this.remoteDataSource,
    required this.stagingStore,
    required this.draftRepository,
    required this.eventBus,
  });

  final AttachmentsRemoteDataSource remoteDataSource;
  final OutboxAttachmentStagingStore stagingStore;
  final DocumentDraftRepository draftRepository;
  final AppEventBus eventBus;

  @override
  OutboxOperationKind get kind => OutboxOperationKind.attachmentUpload;

  @override
  String get statusScope => 'POST /api/v1/files/upload';

  @override
  Future<Result<OutboxHandlerSuccess>> execute(
    OutboxOperation operation, {
    Map<String, OutboxOperationOutput> dependencyOutputs = const {},
  }) async {
    if (operation.kind != kind) {
      return const FailureResult(
        ValidationFailure(message: 'Attachment outbox handler kind mismatch.'),
      );
    }
    late final _AttachmentPayload payload;
    try {
      payload = _AttachmentPayload.fromJson(operation.payload);
    } on FormatException catch (error) {
      return FailureResult(
        ValidationFailure(message: error.message, cause: error),
      );
    }
    if (payload.requestId != operation.idempotencyKey) {
      return const FailureResult(
        ValidationFailure(message: 'Attachment idempotency key changed.'),
      );
    }
    final dependencyDocumentIds = dependencyOutputs.values
        .map((output) => output.data['documentId'])
        .whereType<int>()
        .where((id) => id > 0)
        .toSet();
    if (payload.localAggregateId != null) {
      if (dependencyDocumentIds.length != 1) {
        return const FailureResult(
          ValidationFailure(
            message: 'Draft attachment requires authoritative document output.',
          ),
        );
      }
      final rebound = await stagingStore.rebindDocumentDraft(
        userId: operation.accountId,
        localAggregateId: payload.localAggregateId!,
        documentId: dependencyDocumentIds.single,
        requestIds: [payload.requestId],
      );
      if (rebound case FailureResult<void>(:final failure)) {
        return FailureResult(failure);
      }
    }
    final loaded = await stagingStore.loadStaged(
      userId: operation.accountId,
      requestId: payload.requestId,
    );
    if (loaded case FailureResult(:final failure)) {
      return FailureResult(failure);
    }
    final staged = (loaded as Success).data;
    if (staged.pending.fileSize != payload.expectedSize ||
        staged.sha256 != payload.expectedSha256) {
      return const FailureResult(
        ValidationFailure(message: 'Staged attachment changed after review.'),
      );
    }
    if (staged.pending.binding.businessType == 'document_draft' ||
        staged.pending.binding.localDraftId != null ||
        staged.pending.binding.businessId <= 0) {
      return const FailureResult(
        ValidationFailure(
          message: 'Draft attachment has no authoritative document binding.',
        ),
      );
    }
    final uploaded = await remoteDataSource.upload(
      staged.pending,
      onProgress: (_, _) {},
      cancellation: TransferCancellation(),
    );
    if (uploaded case FailureResult(:final failure)) {
      return FailureResult(failure);
    }

    final model = (uploaded as Success).data;
    return Success(
      OutboxHandlerSuccess(
        output: OutboxOperationOutput(
          version: 1,
          data: {
            'attachmentId': model.id,
            'documentId': staged.pending.binding.businessId,
          },
        ),
        cleanup:
            payload.cleanup?.toRequest() ??
            (payload.localAggregateId == null
                ? OutboxCleanupRequest(
                    attachmentRequestIds: [payload.requestId],
                  )
                : null),
      ),
    );
  }
}

final class _AttachmentPayload {
  const _AttachmentPayload({
    required this.requestId,
    required this.expectedSize,
    required this.expectedSha256,
    required this.localAggregateId,
    required this.cleanup,
  });

  factory _AttachmentPayload.fromJson(Map<String, Object?> json) {
    const allowed = {
      'version',
      'requestId',
      'expectedSize',
      'expectedSha256',
      'localAggregateId',
      'cleanup',
    };
    const required = {'version', 'requestId', 'expectedSize', 'expectedSha256'};
    if (json.keys.any((key) => !allowed.contains(key)) ||
        required.any((key) => !json.containsKey(key)) ||
        json['version'] != 1) {
      throw const FormatException(
        'Invalid or unsupported attachment outbox payload.',
      );
    }
    final requestId = _string(json, 'requestId');
    final size = json['expectedSize'];
    final hash = _string(json, 'expectedSha256');
    if (size is! int || size < 0 || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid attachment snapshot metadata.');
    }
    final localAggregateId = json['localAggregateId'];
    if (localAggregateId != null &&
        (localAggregateId is! String || localAggregateId.trim().isEmpty)) {
      throw const FormatException('Invalid attachment local aggregate ID.');
    }
    return _AttachmentPayload(
      requestId: requestId,
      expectedSize: size,
      expectedSha256: hash,
      localAggregateId: localAggregateId as String?,
      cleanup: json['cleanup'] == null
          ? null
          : _AttachmentCleanup.fromJson(_map(json, 'cleanup')),
    );
  }

  final String requestId;
  final int expectedSize;
  final String expectedSha256;
  final String? localAggregateId;
  final _AttachmentCleanup? cleanup;
}

final class _AttachmentCleanup {
  const _AttachmentCleanup({
    required this.draftId,
    required this.attachmentRequestIds,
  });

  factory _AttachmentCleanup.fromJson(Map<String, Object?> json) {
    if (json.length != 2 ||
        !json.containsKey('draftId') ||
        !json.containsKey('attachmentRequestIds')) {
      throw const FormatException('Invalid attachment cleanup payload.');
    }
    final ids = json['attachmentRequestIds'];
    if (ids is! List<Object?> ||
        ids.isEmpty ||
        ids.any((item) => item is! String || item.trim().isEmpty)) {
      throw const FormatException('Invalid attachment cleanup request IDs.');
    }
    final values = ids.cast<String>();
    if (values.toSet().length != values.length) {
      throw const FormatException('Duplicate attachment cleanup request ID.');
    }
    return _AttachmentCleanup(
      draftId: _string(json, 'draftId'),
      attachmentRequestIds: List.unmodifiable(values),
    );
  }

  final String draftId;
  final List<String> attachmentRequestIds;

  OutboxCleanupRequest toRequest() => OutboxCleanupRequest(
    draftId: draftId,
    attachmentRequestIds: attachmentRequestIds,
  );
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('Invalid attachment payload string.');
  }
  return value;
}

Map<String, Object?> _map(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) {
    throw const FormatException('Invalid attachment payload object.');
  }
  return Map<String, Object?>.from(value);
}
