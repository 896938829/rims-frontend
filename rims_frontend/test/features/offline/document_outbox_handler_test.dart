import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/events/app_event.dart';
import 'package:rims_frontend/core/events/app_event_bus.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_staging_store.dart';
import 'package:rims_frontend/features/documents/data/datasources/documents_remote_datasource.dart';
import 'package:rims_frontend/features/documents/data/models/document_models.dart';
import 'package:rims_frontend/features/documents/domain/entities/document_data.dart';
import 'package:rims_frontend/features/offline/data/services/document_outbox_handler.dart';
import 'package:rims_frontend/features/offline/domain/entities/document_draft.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_graph.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_executor.dart';
import 'package:rims_frontend/features/offline/domain/repositories/document_draft_repository.dart';

void main() {
  late _DocumentsDataSource dataSource;
  late _SubmissionStagingStore stagingStore;
  late _DraftRepository draftRepository;
  late AppEventBus eventBus;
  late List<AppEvent> events;

  setUp(() {
    dataSource = _DocumentsDataSource();
    stagingStore = _SubmissionStagingStore();
    draftRepository = _DraftRepository();
    eventBus = AppEventBus();
    events = [];
    eventBus.on<AppEvent>().listen(events.add);
  });

  tearDown(() => eventBus.dispose());

  test('strictly rejects an unsupported document payload version', () async {
    final handler = DocumentOutboxHandler(
      kind: OutboxOperationKind.documentCreate,
      remoteDataSource: dataSource,
      stagingStore: stagingStore,
      draftRepository: draftRepository,
      eventBus: eventBus,
    );

    final result = await handler.execute(
      _operation(payload: {..._createPayload(), 'version': 2}),
    );

    expect(result.failureOrNull, isA<ValidationFailure>());
    expect(dataSource.createRequests, isEmpty);
  });

  test(
    'create replays the immutable request key and then rebinds its draft files',
    () async {
      final handler = DocumentOutboxHandler(
        kind: OutboxOperationKind.documentCreate,
        remoteDataSource: dataSource,
        stagingStore: stagingStore,
        draftRepository: draftRepository,
        eventBus: eventBus,
      );

      final result = await handler.execute(_operation());

      expect(result, isA<Success<Object?>>());
      expect(dataSource.createRequests, hasLength(1));
      expect(dataSource.createRequests.single.requestId, 'document-request-1');
      expect(
        dataSource.createRequests.single.effectiveLines.single.productId,
        7,
      );
      final success = (result as Success<OutboxHandlerSuccess>).data;
      expect(success.output.data, {'documentId': 91});
      expect(stagingStore.rebindCalls, isEmpty);
      expect(draftRepository.deletedDraftIds, isEmpty);
      expect(events, isEmpty);
    },
  );

  test('server validation preserves draft and staged files', () async {
    dataSource.createResult = const FailureResult(
      ValidationFailure(message: 'server rejected lines'),
    );
    final handler = DocumentOutboxHandler(
      kind: OutboxOperationKind.documentCreate,
      remoteDataSource: dataSource,
      stagingStore: stagingStore,
      draftRepository: draftRepository,
      eventBus: eventBus,
    );

    final result = await handler.execute(_operation());

    expect(result.failureOrNull, isA<ValidationFailure>());
    expect(stagingStore.rebindCalls, isEmpty);
    expect(stagingStore.removeCalls, isEmpty);
    expect(draftRepository.deletedDraftIds, isEmpty);
    expect(events, isEmpty);
  });

  test(
    'unknown create result preserves evidence for status-first replay',
    () async {
      dataSource.createResult = const FailureResult(
        UnknownFailure(message: 'response was lost'),
      );
      final handler = DocumentOutboxHandler(
        kind: OutboxOperationKind.documentCreate,
        remoteDataSource: dataSource,
        stagingStore: stagingStore,
        draftRepository: draftRepository,
        eventBus: eventBus,
      );

      final result = await handler.execute(
        _operation(requiresStatusProbe: true),
      );

      expect(result.failureOrNull, isA<UnknownFailure>());
      expect(dataSource.createRequests.single.requestId, 'document-request-1');
      expect(stagingStore.rebindCalls, isEmpty);
      expect(draftRepository.deletedDraftIds, isEmpty);
    },
  );

  test('create rejects cleanup ownership reserved for lifecycle', () async {
    final handler = DocumentOutboxHandler(
      kind: OutboxOperationKind.documentCreate,
      remoteDataSource: dataSource,
      stagingStore: stagingStore,
      draftRepository: draftRepository,
      eventBus: eventBus,
    );

    final result = await handler.execute(
      _operation(
        payload: {
          ..._createPayload(),
          'attachmentRequestIds': const <Object?>[],
          'cleanup': const {
            'draftId': 'draft-1',
            'attachmentRequestIds': <Object?>[],
          },
        },
      ),
    );

    expect(result.failureOrNull, isA<ValidationFailure>());
    expect(dataSource.createRequests, isEmpty);
    expect(draftRepository.deletedDraftIds, isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(events.whereType<GlobalRefreshRequestedEvent>(), isEmpty);
  });

  test(
    'lifecycle reads authoritative id only from explicit dependency output',
    () async {
      final handler = DocumentOutboxHandler(
        kind: OutboxOperationKind.documentComplete,
        remoteDataSource: dataSource,
        stagingStore: stagingStore,
        draftRepository: draftRepository,
        eventBus: eventBus,
      );
      final operation = _operation(
        kind: OutboxOperationKind.documentComplete,
        operationId: 'complete-document-request-1',
        idempotencyKey: 'complete-request-1',
        payload: const {
          'version': 1,
          'cleanup': {
            'draftId': 'draft-1',
            'attachmentRequestIds': ['attachment-request-1'],
          },
        },
      );

      final result = await handler.execute(
        operation,
        dependencyOutputs: {
          'create-document-request-1': OutboxOperationOutput(
            version: 1,
            data: {'documentId': 91},
          ),
        },
      );

      expect(result, isA<Success<OutboxHandlerSuccess>>());
      final success = (result as Success<OutboxHandlerSuccess>).data;
      expect(success.output.data, {
        'documentId': 91,
        'operationKind': 'document_complete',
      });
      expect(success.cleanup?.draftId, 'draft-1');
      expect(success.cleanup?.attachmentRequestIds, ['attachment-request-1']);
      expect(dataSource.events, ['complete:91']);
      expect(dataSource.lifecycleRequestIds, ['complete-request-1']);
    },
  );

  test('lifecycle rejects missing authoritative dependency output', () async {
    final handler = DocumentOutboxHandler(
      kind: OutboxOperationKind.documentComplete,
      remoteDataSource: dataSource,
      stagingStore: stagingStore,
      draftRepository: draftRepository,
      eventBus: eventBus,
    );

    final result = await handler.execute(
      _operation(
        kind: OutboxOperationKind.documentComplete,
        operationId: 'complete-document-request-1',
        idempotencyKey: 'complete-request-1',
        payload: const {'version': 1},
      ),
    );

    expect(result.failureOrNull, isA<ValidationFailure>());
    expect(dataSource.events, isEmpty);
  });

  test(
    'lifecycle strictly validates its single direct dependency output',
    () async {
      final handler = DocumentOutboxHandler(
        kind: OutboxOperationKind.documentComplete,
        remoteDataSource: dataSource,
        stagingStore: stagingStore,
        draftRepository: draftRepository,
        eventBus: eventBus,
      );
      final operation = _operation(
        kind: OutboxOperationKind.documentComplete,
        operationId: 'complete-document-request-1',
        idempotencyKey: 'complete-request-1',
        payload: const {'version': 1},
      );
      final valid = OutboxOperationOutput(version: 1, data: {'documentId': 91});
      final malformed = <Map<String, OutboxOperationOutput>>[
        {
          'parent': OutboxOperationOutput(version: 2, data: {'documentId': 91}),
        },
        {
          'parent': OutboxOperationOutput(
            version: 1,
            data: {'documentId': 91, 'unexpected': true},
          ),
        },
        {
          'parent': OutboxOperationOutput(
            version: 1,
            data: {'attachmentId': 5},
          ),
        },
        {
          'parent': OutboxOperationOutput(version: 1, data: {'documentId': 0}),
        },
        {
          'parent': OutboxOperationOutput(
            version: 1,
            data: {'documentId': 91, 'operationKind': 'unknown'},
          ),
        },
        {'parent-a': valid, 'parent-b': valid},
      ];

      for (final outputs in malformed) {
        final result = await handler.execute(
          operation,
          dependencyOutputs: outputs,
        );
        expect(result.failureOrNull, isA<ValidationFailure>());
      }
      expect(dataSource.events, isEmpty);
    },
  );

  test(
    'complete and stocktake confirm accept only document or attachment output',
    () async {
      for (final kind in [
        OutboxOperationKind.documentComplete,
        OutboxOperationKind.stocktakeConfirm,
      ]) {
        final handler = DocumentOutboxHandler(
          kind: kind,
          remoteDataSource: dataSource,
          stagingStore: stagingStore,
          draftRepository: draftRepository,
          eventBus: eventBus,
        );
        for (final valid in [
          OutboxOperationOutput(version: 1, data: {'documentId': 91}),
          OutboxOperationOutput(
            version: 1,
            data: {'attachmentId': 17, 'documentId': 91},
          ),
        ]) {
          final result = await handler.execute(
            _operation(
              kind: kind,
              operationId: '${kind.wireValue}-request',
              idempotencyKey: '${kind.wireValue}.request',
              payload: const {'version': 1},
            ),
            dependencyOutputs: {'parent': valid},
          );
          expect(result, isA<Success<OutboxHandlerSuccess>>());
        }

        final callsBeforeInvalid = dataSource.events.length;
        for (final invalid in [
          OutboxOperationOutput(
            version: 1,
            data: {'documentId': 91, 'operationKind': 'stocktake_confirm'},
          ),
          OutboxOperationOutput(
            version: 1,
            data: {'documentId': 91, 'operationKind': 'stocktake_settle'},
          ),
        ]) {
          final result = await handler.execute(
            _operation(
              kind: kind,
              operationId: '${kind.wireValue}-invalid',
              idempotencyKey: '${kind.wireValue}.invalid',
              payload: const {'version': 1},
            ),
            dependencyOutputs: {'parent': invalid},
          );
          expect(result.failureOrNull, isA<ValidationFailure>());
        }
        expect(dataSource.events, hasLength(callsBeforeInvalid));
      }
    },
  );

  test(
    'stocktake settle accepts only exact stocktake confirm lifecycle output',
    () async {
      final handler = DocumentOutboxHandler(
        kind: OutboxOperationKind.stocktakeSettle,
        remoteDataSource: dataSource,
        stagingStore: stagingStore,
        draftRepository: draftRepository,
        eventBus: eventBus,
      );
      final operation = _operation(
        kind: OutboxOperationKind.stocktakeSettle,
        operationId: 'settle-document-request-1',
        idempotencyKey: 'document-request-1.stocktake_settle',
        payload: const {'version': 1},
      );

      final valid = await handler.execute(
        operation,
        dependencyOutputs: {
          'confirm': OutboxOperationOutput(
            version: 1,
            data: {'documentId': 91, 'operationKind': 'stocktake_confirm'},
          ),
        },
      );
      expect(valid, isA<Success<OutboxHandlerSuccess>>());
      expect((valid as Success<OutboxHandlerSuccess>).data.output.data, {
        'documentId': 91,
        'operationKind': 'stocktake_settle',
      });

      final callsBeforeInvalid = dataSource.events.length;
      final invalid = <OutboxOperationOutput>[
        OutboxOperationOutput(version: 1, data: {'documentId': 91}),
        OutboxOperationOutput(
          version: 1,
          data: {'attachmentId': 17, 'documentId': 91},
        ),
        OutboxOperationOutput(
          version: 1,
          data: {'documentId': 91, 'operationKind': 'document_complete'},
        ),
        OutboxOperationOutput(
          version: 1,
          data: {'documentId': 91, 'operationKind': 'stocktake_settle'},
        ),
        OutboxOperationOutput(
          version: 1,
          data: {
            'documentId': 91,
            'operationKind': 'stocktake_confirm',
            'extra': true,
          },
        ),
      ];
      for (final output in invalid) {
        final result = await handler.execute(
          operation,
          dependencyOutputs: {'parent': output},
        );
        expect(result.failureOrNull, isA<ValidationFailure>());
      }
      expect(dataSource.events, hasLength(callsBeforeInvalid));
    },
  );
}

Map<String, Object?> _createPayload() => {
  'version': 1,
  'localAggregateId': 'draft-1',
  'attachmentRequestIds': const ['attachment-request-1'],
  'request': {
    'docType': 1,
    'typeLabel': '采购入库',
    'requestId': 'document-request-1',
    'lines': const [
      {
        'productId': 7,
        'productName': 'Widget',
        'quantity': 3,
        'retailPrice': 12.5,
      },
    ],
    'remark': 'immutable snapshot',
  },
};

OutboxOperation _operation({
  OutboxOperationKind kind = OutboxOperationKind.documentCreate,
  String operationId = 'create-document-request-1',
  String idempotencyKey = 'document-request-1',
  Map<String, Object?>? payload,
  bool requiresStatusProbe = false,
}) => OutboxOperation(
  operationId: operationId,
  idempotencyKey: idempotencyKey,
  accountId: '42',
  warehouseId: 8,
  kind: kind,
  payload: payload ?? _createPayload(),
  state: OutboxState.queued,
  createdAt: DateTime.utc(2026, 7, 13),
  requiresStatusProbe: requiresStatusProbe,
);

final class _DocumentsDataSource implements DocumentsRemoteDataSource {
  Result<DocumentRecordModel> createResult = const Success(
    DocumentRecordModel(
      id: 91,
      docType: 1,
      title: '采购入库',
      number: 'DOC-91',
      status: '草稿',
      productName: 'Widget',
      quantity: 3,
      remark: '',
      createdAt: '2026-07-13T00:00:00Z',
    ),
  );
  final List<CreateDocumentRequest> createRequests = [];
  final List<String> events = [];
  final List<String> lifecycleRequestIds = [];

  @override
  Future<Result<DocumentRecordModel>> createDocument(
    CreateDocumentRequest request,
  ) async {
    createRequests.add(request);
    events.add('create:${request.requestId}');
    return createResult;
  }

  @override
  Future<Result<void>> completeDocument(int id, {String? requestId}) async {
    events.add('complete:$id');
    lifecycleRequestIds.add(requestId ?? '');
    return const Success(null);
  }

  @override
  Future<Result<void>> confirmDocument(int id, {String? requestId}) async {
    events.add('confirm:$id');
    lifecycleRequestIds.add(requestId ?? '');
    return const Success(null);
  }

  @override
  Future<Result<void>> settleDocument(int id, {String? requestId}) async {
    events.add('settle:$id');
    lifecycleRequestIds.add(requestId ?? '');
    return const Success(null);
  }

  @override
  Future<Result<DocumentDetailModel>> getDocument(int id) =>
      throw UnimplementedError();

  @override
  Future<Result<PageData<DocumentRecordModel>>> listRecentDocuments({
    int? docType,
    int page = 1,
  }) => throw UnimplementedError();

  @override
  Future<Result<PageData<TransactionRecordModel>>> listTransactions({
    String keyword = '',
    int page = 1,
  }) => throw UnimplementedError();
}

final class _SubmissionStagingStore implements OutboxAttachmentStagingStore {
  final List<_RebindCall> rebindCalls = [];
  final List<List<String>> removeCalls = [];

  @override
  Future<Result<void>> rebindDocumentDraft({
    required String userId,
    required String localAggregateId,
    required int documentId,
    required List<String> requestIds,
  }) async {
    rebindCalls.add(
      _RebindCall(
        userId: userId,
        localAggregateId: localAggregateId,
        documentId: documentId,
        requestIds: List.unmodifiable(requestIds),
      ),
    );
    return const Success(null);
  }

  @override
  Future<Result<StagedAttachment>> loadStaged({
    required String userId,
    required String requestId,
  }) => throw UnimplementedError();

  @override
  Future<Result<void>> removeStagedAttachments({
    required String userId,
    required List<String> requestIds,
  }) async {
    removeCalls.add(List.unmodifiable(requestIds));
    return const Success(null);
  }
}

final class _RebindCall {
  const _RebindCall({
    required this.userId,
    required this.localAggregateId,
    required this.documentId,
    required this.requestIds,
  });

  final String userId;
  final String localAggregateId;
  final int documentId;
  final List<String> requestIds;

  @override
  bool operator ==(Object other) =>
      other is _RebindCall &&
      other.userId == userId &&
      other.localAggregateId == localAggregateId &&
      other.documentId == documentId &&
      _listEquals(other.requestIds, requestIds);

  @override
  int get hashCode => Object.hash(userId, localAggregateId, documentId);
}

bool _listEquals(List<Object?> left, List<Object?> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final class _DraftRepository implements DocumentDraftRepository {
  final List<String> deletedDraftIds = [];

  @override
  Future<void> delete({
    required String accountId,
    required String draftId,
  }) async {
    deletedDraftIds.add(draftId);
  }

  @override
  Future<Result<DocumentDraft>> save(
    DocumentDraft draft, {
    required int expectedVersion,
  }) => throw UnimplementedError();

  @override
  Future<DocumentDraft?> load({
    required String accountId,
    required String draftId,
  }) => throw UnimplementedError();

  @override
  Future<List<DocumentDraft>> list(String accountId) =>
      throw UnimplementedError();

  @override
  Future<void> prune() => throw UnimplementedError();
}

extension on Result<dynamic> {
  Failure? get failureOrNull => switch (this) {
    FailureResult<Object?>(:final failure) => failure,
    _ => null,
  };
}
