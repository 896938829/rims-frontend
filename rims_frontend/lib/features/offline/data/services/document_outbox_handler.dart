import '../../../../core/events/app_event_bus.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../attachments/domain/services/attachment_staging_store.dart';
import '../../../documents/data/datasources/documents_remote_datasource.dart';
import '../../../documents/data/models/document_models.dart';
import '../../../documents/domain/entities/document_data.dart';
import '../../domain/entities/outbox_operation.dart';
import '../../domain/entities/outbox_graph.dart';
import '../../domain/entities/outbox_cleanup_intent.dart';
import '../../domain/repositories/document_draft_repository.dart';
import '../../domain/services/outbox_executor.dart';
import 'outbox_dependency_output_parser.dart';

final class DocumentOutboxHandler implements OutboxOperationHandler {
  const DocumentOutboxHandler({
    required this.kind,
    required this.remoteDataSource,
    required this.stagingStore,
    required this.draftRepository,
    required this.eventBus,
  }) : assert(
         kind == OutboxOperationKind.documentReference ||
             kind == OutboxOperationKind.documentCreate ||
             kind == OutboxOperationKind.documentComplete ||
             kind == OutboxOperationKind.stocktakeConfirm ||
             kind == OutboxOperationKind.stocktakeSettle,
       );

  @override
  final OutboxOperationKind kind;
  final DocumentsRemoteDataSource remoteDataSource;
  final OutboxAttachmentStagingStore stagingStore;
  final DocumentDraftRepository draftRepository;
  final AppEventBus eventBus;

  @override
  String get statusScope => switch (kind) {
    OutboxOperationKind.documentReference => 'GET /api/v1/documents/:id',
    OutboxOperationKind.documentCreate => 'POST /api/v1/documents',
    OutboxOperationKind.documentComplete =>
      'POST /api/v1/documents/:id/complete',
    OutboxOperationKind.stocktakeConfirm =>
      'POST /api/v1/documents/:id/confirm',
    OutboxOperationKind.stocktakeSettle => 'POST /api/v1/documents/:id/settle',
    _ => throw StateError('Unsupported document outbox kind.'),
  };

  @override
  Future<Result<OutboxHandlerSuccess>> execute(
    OutboxOperation operation, {
    Map<String, OutboxOperationOutput> dependencyOutputs = const {},
  }) async {
    if (operation.kind != kind) {
      return const FailureResult(
        ValidationFailure(message: 'Document outbox handler kind mismatch.'),
      );
    }
    if ((kind == OutboxOperationKind.documentReference ||
            kind == OutboxOperationKind.documentCreate) &&
        dependencyOutputs.isNotEmpty) {
      return const FailureResult(
        ValidationFailure(
          message: 'Document root operation cannot have dependency outputs.',
        ),
      );
    }
    try {
      return switch (kind) {
        OutboxOperationKind.documentReference => await _executeReference(
          operation,
        ),
        OutboxOperationKind.documentCreate => await _executeCreate(operation),
        _ => await _executeLifecycle(operation, dependencyOutputs),
      };
    } on FormatException catch (error) {
      return FailureResult(
        ValidationFailure(message: error.message, cause: error),
      );
    }
  }

  Future<Result<OutboxHandlerSuccess>> _executeReference(
    OutboxOperation operation,
  ) async {
    final payload = _DocumentReferencePayload.fromJson(operation.payload);
    final loaded = await remoteDataSource.getDocument(payload.documentId);
    if (loaded case FailureResult<DocumentDetailModel>(:final failure)) {
      return FailureResult(failure);
    }
    final record = (loaded as Success<DocumentDetailModel>).data.record;
    if (record.id != payload.documentId ||
        record.docType != payload.expectedDocType) {
      return const FailureResult(
        ValidationFailure(
          message: 'Authoritative document type does not match the review.',
        ),
      );
    }
    if (record.status != payload.expectedStatus) {
      return const FailureResult(
        ConflictFailure(
          message: 'Authoritative document state changed after review.',
        ),
      );
    }
    return Success(
      OutboxHandlerSuccess(
        output: OutboxOperationOutput(
          version: 1,
          data: {
            'operationKind': payload.outputMarker,
            'documentId': payload.documentId,
          },
        ),
      ),
    );
  }

  Future<Result<OutboxHandlerSuccess>> _executeCreate(
    OutboxOperation operation,
  ) async {
    final payload = _DocumentCreatePayload.fromJson(
      operation.payload,
      expectedRequestId: operation.idempotencyKey,
    );
    final result = await remoteDataSource.createDocument(payload.request);
    if (result case FailureResult(:final failure)) {
      return FailureResult(failure);
    }
    final model = (result as Success).data;
    if (model.id <= 0) {
      return const FailureResult(
        UnknownFailure(message: 'Document create returned an invalid ID.'),
      );
    }
    return Success(
      OutboxHandlerSuccess(
        output: OutboxOperationOutput(
          version: 1,
          data: {'documentId': model.id},
        ),
      ),
    );
  }

  Future<Result<OutboxHandlerSuccess>> _executeLifecycle(
    OutboxOperation operation,
    Map<String, OutboxOperationOutput> dependencyOutputs,
  ) async {
    final payload = _DocumentLifecyclePayload.fromJson(operation.payload);
    final documentId = requireAuthoritativeDocumentId(
      dependencyOutputs,
      allowedShapes: kind == OutboxOperationKind.stocktakeSettle
          ? const {OutboxDependencyOutputShape.lifecycle}
          : const {
              OutboxDependencyOutputShape.document,
              OutboxDependencyOutputShape.attachment,
              OutboxDependencyOutputShape.lifecycle,
            },
      allowedLifecycleOperationKinds: switch (kind) {
        OutboxOperationKind.documentComplete => const {
          'document_complete_reference',
        },
        OutboxOperationKind.stocktakeConfirm => const {
          'stocktake_confirm_reference',
        },
        OutboxOperationKind.stocktakeSettle => const {
          'stocktake_confirm',
          'stocktake_settle_reference',
        },
        _ => null,
      },
    );
    final Result<void> result = switch (kind) {
      OutboxOperationKind.documentComplete =>
        await remoteDataSource.completeDocument(
          documentId,
          requestId: operation.idempotencyKey,
        ),
      OutboxOperationKind.stocktakeConfirm =>
        await remoteDataSource.confirmDocument(
          documentId,
          requestId: operation.idempotencyKey,
        ),
      OutboxOperationKind.stocktakeSettle =>
        await remoteDataSource.settleDocument(
          documentId,
          requestId: operation.idempotencyKey,
        ),
      _ => throw StateError('Unsupported lifecycle kind.'),
    };
    if (result case FailureResult<void>(:final failure)) {
      return FailureResult(failure);
    }
    return Success(
      OutboxHandlerSuccess(
        output: OutboxOperationOutput(
          version: 1,
          data: {'documentId': documentId, 'operationKind': kind.wireValue},
        ),
        cleanup: payload.cleanup?.toRequest(),
      ),
    );
  }
}

final class _DocumentReferencePayload {
  const _DocumentReferencePayload({
    required this.documentId,
    required this.expectedDocType,
    required this.expectedStatus,
    required this.outputMarker,
  });

  factory _DocumentReferencePayload.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'version',
      'documentId',
      'expectedDocType',
      'expectedStatus',
      'lifecycleIntent',
    });
    _expectVersion(json);
    final documentId = _positiveInt(json, 'documentId');
    final expectedDocType = _positiveInt(json, 'expectedDocType');
    final expectedStatus = _string(json, 'expectedStatus');
    final lifecycleIntent = _string(json, 'lifecycleIntent');
    final outputMarker = switch (lifecycleIntent) {
      'document_complete'
          when expectedDocType != 5 &&
              (expectedStatus == '待提交' || expectedStatus == '草稿') =>
        'document_complete_reference',
      'stocktake_confirm'
          when expectedDocType == 5 && expectedStatus == '盘点中' =>
        'stocktake_confirm_reference',
      'stocktake_settle'
          when expectedDocType == 5 && expectedStatus == '差异已确认' =>
        'stocktake_settle_reference',
      _ => throw const FormatException(
        'Document reference lifecycle intent is inconsistent.',
      ),
    };
    return _DocumentReferencePayload(
      documentId: documentId,
      expectedDocType: expectedDocType,
      expectedStatus: expectedStatus,
      outputMarker: outputMarker,
    );
  }

  final int documentId;
  final int expectedDocType;
  final String expectedStatus;
  final String outputMarker;
}

final class _DocumentCreatePayload {
  const _DocumentCreatePayload({
    required this.localAggregateId,
    required this.attachmentRequestIds,
    required this.request,
  });

  factory _DocumentCreatePayload.fromJson(
    Map<String, Object?> json, {
    required String expectedRequestId,
  }) {
    _expectKeys(json, const {
      'version',
      'localAggregateId',
      'attachmentRequestIds',
      'request',
    });
    _expectVersion(json);
    final localAggregateId = _string(json, 'localAggregateId');
    final attachments = _stringList(json, 'attachmentRequestIds');
    return _DocumentCreatePayload(
      localAggregateId: localAggregateId,
      attachmentRequestIds: attachments,
      request: _request(
        _map(json, 'request'),
        expectedRequestId: expectedRequestId,
      ),
    );
  }

  final String localAggregateId;
  final List<String> attachmentRequestIds;
  final CreateDocumentRequest request;
}

final class _DocumentLifecyclePayload {
  const _DocumentLifecyclePayload({required this.cleanup});

  factory _DocumentLifecyclePayload.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {'version', 'cleanup'},
      optional: const {'cleanup'},
    );
    _expectVersion(json);
    return _DocumentLifecyclePayload(
      cleanup: json['cleanup'] == null
          ? null
          : _OutboxCleanup.fromJson(_map(json, 'cleanup')),
    );
  }

  final _OutboxCleanup? cleanup;
}

final class _OutboxCleanup {
  const _OutboxCleanup({
    required this.draftId,
    required this.attachmentRequestIds,
  });

  factory _OutboxCleanup.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {'draftId', 'attachmentRequestIds'});
    return _OutboxCleanup(
      draftId: _string(json, 'draftId'),
      attachmentRequestIds: _stringList(json, 'attachmentRequestIds'),
    );
  }

  final String draftId;
  final List<String> attachmentRequestIds;

  OutboxCleanupRequest toRequest() => OutboxCleanupRequest(
    draftId: draftId,
    attachmentRequestIds: attachmentRequestIds,
  );
}

CreateDocumentRequest _request(
  Map<String, Object?> json, {
  String? expectedRequestId,
}) {
  _expectKeys(
    json,
    const {
      'docType',
      'typeLabel',
      'requestId',
      'lines',
      'toWarehouseId',
      'refDocId',
      'remark',
    },
    optional: const {'toWarehouseId', 'refDocId'},
  );
  final requestId = _string(json, 'requestId');
  if (expectedRequestId != null && requestId != expectedRequestId) {
    throw const FormatException('Document idempotency key changed.');
  }
  final rawLines = json['lines'];
  if (rawLines is! List<Object?> || rawLines.isEmpty) {
    throw const FormatException('Document payload lines are invalid.');
  }
  final lines = rawLines
      .map((raw) {
        if (raw is! Map) {
          throw const FormatException('Document payload line is invalid.');
        }
        final line = Map<String, Object?>.from(raw);
        _expectKeys(
          line,
          const {
            'productId',
            'productName',
            'quantity',
            'actualQuantity',
            'nonStandardInventoryId',
            'retailPrice',
          },
          optional: const {
            'actualQuantity',
            'nonStandardInventoryId',
            'retailPrice',
          },
        );
        final retailPrice = line['retailPrice'];
        if (retailPrice != null && retailPrice is! num) {
          throw const FormatException('Document retail price is invalid.');
        }
        return CreateDocumentLineRequest(
          productId: _positiveInt(line, 'productId'),
          productName: _string(line, 'productName'),
          quantity: _int(line, 'quantity'),
          actualQuantity: _optionalInt(line, 'actualQuantity'),
          nonStandardInventoryId: _optionalPositiveInt(
            line,
            'nonStandardInventoryId',
          ),
          retailPrice: (retailPrice as num?)?.toDouble(),
        );
      })
      .toList(growable: false);
  return CreateDocumentRequest(
    docType: _positiveInt(json, 'docType'),
    typeLabel: _string(json, 'typeLabel'),
    requestId: requestId,
    lines: List.unmodifiable(lines),
    toWarehouseId: _optionalPositiveInt(json, 'toWarehouseId'),
    refDocId: _optionalPositiveInt(json, 'refDocId'),
    remark: _string(json, 'remark', allowEmpty: true),
  );
}

void _expectVersion(Map<String, Object?> json) {
  if (json['version'] != 1) {
    throw const FormatException('Unsupported document outbox payload version.');
  }
}

void _expectKeys(
  Map<String, Object?> json,
  Set<String> allowed, {
  Set<String> optional = const {},
}) {
  if (json.keys.any((key) => !allowed.contains(key)) ||
      allowed.difference(optional).any((key) => !json.containsKey(key))) {
    throw const FormatException('Invalid document outbox payload shape.');
  }
}

Map<String, Object?> _map(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw const FormatException('Invalid payload object.');
  return Map<String, Object?>.from(value);
}

String _string(
  Map<String, Object?> json,
  String key, {
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
    throw const FormatException('Invalid payload string.');
  }
  return value;
}

List<String> _stringList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List<Object?> ||
      value.any((item) => item is! String || item.trim().isEmpty)) {
    throw const FormatException('Invalid payload string list.');
  }
  final values = value.cast<String>();
  if (values.toSet().length != values.length) {
    throw const FormatException('Payload string list contains duplicates.');
  }
  return List.unmodifiable(values);
}

int _int(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) throw const FormatException('Invalid payload integer.');
  return value;
}

int _positiveInt(Map<String, Object?> json, String key) {
  final value = _int(json, key);
  if (value <= 0) throw const FormatException('Invalid positive integer.');
  return value;
}

int? _optionalInt(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) return null;
  return _int(json, key);
}

int? _optionalPositiveInt(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) return null;
  return _positiveInt(json, key);
}
