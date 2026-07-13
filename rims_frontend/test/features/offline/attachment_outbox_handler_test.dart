import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/events/app_event.dart';
import 'package:rims_frontend/core/events/app_event_bus.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/attachments/data/datasources/attachments_remote_datasource.dart';
import 'package:rims_frontend/features/attachments/data/models/attachment_models.dart';
import 'package:rims_frontend/features/attachments/data/services/file_attachment_staging_store.dart';
import 'package:rims_frontend/features/attachments/domain/entities/attachment.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_picker.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_staging_store.dart';
import 'package:rims_frontend/features/documents/data/datasources/documents_remote_datasource.dart';
import 'package:rims_frontend/features/documents/data/models/document_models.dart';
import 'package:rims_frontend/features/documents/domain/entities/document_data.dart';
import 'package:rims_frontend/features/offline/data/services/attachment_outbox_handler.dart';
import 'package:rims_frontend/features/offline/data/services/document_outbox_handler.dart';
import 'package:rims_frontend/features/offline/data/services/outbox_cleanup_coordinator.dart';
import 'package:rims_frontend/features/offline/data/datasources/operation_status_remote_datasource.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/network_reachability.dart';
import 'package:rims_frontend/features/offline/domain/entities/document_draft.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_graph.dart';
import 'package:rims_frontend/features/offline/domain/repositories/document_draft_repository.dart';
import 'package:rims_frontend/features/offline/domain/services/network_status_service.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_executor.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_state_machine.dart';

void main() {
  late _AttachmentsDataSource dataSource;
  late _SubmissionStagingStore stagingStore;
  late _DraftRepository draftRepository;
  late AppEventBus eventBus;
  late List<AppEvent> events;

  setUp(() {
    dataSource = _AttachmentsDataSource();
    stagingStore = _SubmissionStagingStore();
    draftRepository = _DraftRepository();
    eventBus = AppEventBus();
    events = [];
    eventBus.on<AppEvent>().listen(events.add);
  });

  tearDown(() => eventBus.dispose());

  test('strictly rejects malformed and unsupported payloads', () async {
    final handler = _handler(
      dataSource,
      stagingStore,
      draftRepository,
      eventBus,
    );

    final result = await handler.execute(
      _operation(payload: {..._payload(), 'version': 9}),
    );

    expect(result.failureOrNull, isA<ValidationFailure>());
    expect(stagingStore.prepareCalls, isEmpty);
    expect(dataSource.uploads, isEmpty);
  });

  test('strictly rejects a non-SHA-256 attachment snapshot', () async {
    final handler = _handler(
      dataSource,
      stagingStore,
      draftRepository,
      eventBus,
    );

    final result = await handler.execute(
      _operation(payload: {..._payload(), 'expectedSha256': 'not-a-sha256'}),
    );

    expect(result.failureOrNull, isA<ValidationFailure>());
    expect(stagingStore.prepareCalls, isEmpty);
    expect(dataSource.uploads, isEmpty);
  });

  test(
    'process recreation loads the account-owned staged file by request id',
    () async {
      final handler = _handler(
        dataSource,
        stagingStore,
        draftRepository,
        eventBus,
      );

      final result = await handler.execute(
        _operation(),
        dependencyOutputs: {
          'create-document-request-1': OutboxOperationOutput(
            version: 1,
            data: {'documentId': 91},
          ),
        },
      );

      expect(result, isA<Success<Object?>>());
      expect(stagingStore.prepareCalls.single.userId, '42');
      expect(
        stagingStore.prepareCalls.single.requestId,
        'attachment-request-1',
      );
      expect(dataSource.uploads.single.requestId, 'attachment-request-1');
      expect(dataSource.uploads.single.binding, AttachmentBinding.document(91));
      expect(stagingStore.rebindCalls, hasLength(1));
    },
  );

  test(
    'serial draft attachment accepts the prior attachment v1 output',
    () async {
      final handler = _handler(
        dataSource,
        stagingStore,
        draftRepository,
        eventBus,
      );

      final result = await handler.execute(
        _operation(),
        dependencyOutputs: {
          'upload-attachment-request-0': OutboxOperationOutput(
            version: 1,
            data: {'attachmentId': 17, 'documentId': 91},
          ),
        },
      );

      expect(result, isA<Success<OutboxHandlerSuccess>>());
      expect(stagingStore.prepareCalls, hasLength(1));
      expect(stagingStore.rebindCalls.single.documentId, 91);
      expect(dataSource.uploads.single.binding, AttachmentBinding.document(91));
    },
  );

  test(
    'real executor drains create then two serial attachments then complete',
    () async {
      final root = await Directory.systemTemp.createTemp('rims_full_chain_');
      addTearDown(() => root.delete(recursive: true));
      final source1 = File('${root.path}${Platform.pathSeparator}first.pdf');
      final source2 = File('${root.path}${Platform.pathSeparator}second.pdf');
      await source1.writeAsBytes([1, 2, 3]);
      await source2.writeAsBytes([4, 5, 6, 7]);
      var generatedId = 0;
      final fileStore = FileAttachmentStagingStore(
        rootDirectory: () async => root,
        idFactory: () => switch (generatedId++) {
          0 => 'attachment-request-1',
          2 => 'attachment-request-2',
          final value => 'temporary-$value',
        },
        thumbnailBuilder: (_, _) async => null,
      );
      final staged1 =
          (await fileStore.stage(
                    userId: '42',
                    binding: AttachmentBinding.documentDraft('draft-1'),
                    selection: SelectedAttachmentSource(
                      path: source1.path,
                      originalName: 'first.pdf',
                      mimeType: 'application/pdf',
                      fileSize: 3,
                    ),
                    existingCount: 0,
                  )
                  as Success<StagedAttachment>)
              .data;
      final staged2 =
          (await fileStore.stage(
                    userId: '42',
                    binding: AttachmentBinding.documentDraft('draft-1'),
                    selection: SelectedAttachmentSource(
                      path: source2.path,
                      originalName: 'second.pdf',
                      mimeType: 'application/pdf',
                      fileSize: 4,
                    ),
                    existingCount: 1,
                  )
                  as Success<StagedAttachment>)
              .data;
      final chainEvents = <String>[];
      final documents = _ChainDocumentsDataSource(chainEvents);
      final attachments = _ChainAttachmentsDataSource(chainEvents);
      final repository = MemoryOutboxRepository(
        stateMachine: OutboxStateMachine(now: () => DateTime.utc(2026, 7, 13)),
      );
      const reviewStamp = '42\u00008\u0000all@1';
      final createdAt = DateTime.utc(2026, 7, 13);
      OutboxOperation operation({
        required String id,
        required String key,
        required OutboxOperationKind kind,
        required Map<String, Object?> payload,
      }) => OutboxOperation(
        operationId: id,
        idempotencyKey: key,
        accountId: '42',
        warehouseId: 8,
        kind: kind,
        payload: payload,
        state: OutboxState.queued,
        createdAt: createdAt,
        confirmedAt: createdAt,
        reviewStamp: reviewStamp,
      );
      final graph = OutboxGraph(
        operations: [
          operation(
            id: 'create',
            key: 'document-request-1',
            kind: OutboxOperationKind.documentCreate,
            payload: _createDocumentPayload(),
          ),
          for (final staged in [staged1, staged2])
            operation(
              id: 'upload-${staged.pending.requestId}',
              key: staged.pending.requestId,
              kind: OutboxOperationKind.attachmentUpload,
              payload: {
                'version': 1,
                'requestId': staged.pending.requestId,
                'expectedSize': staged.pending.fileSize,
                'expectedSha256': staged.sha256,
                'localAggregateId': 'draft-1',
              },
            ),
          operation(
            id: 'complete',
            key: 'document-request-1.document_complete',
            kind: OutboxOperationKind.documentComplete,
            payload: const {'version': 1},
          ),
        ],
        dependencies: const {
          'upload-attachment-request-1': {'create'},
          'upload-attachment-request-2': {'upload-attachment-request-1'},
          'complete': {'upload-attachment-request-2'},
        },
      );
      expect(await repository.enqueueGraph(graph), isA<Success<Object?>>());
      final executor = OutboxExecutor(
        repository: repository,
        networkStatusService: const _OnlineNetworkStatusService(),
        statusDataSource: const _UnexpectedStatusDataSource(),
        handlers: [
          DocumentOutboxHandler(
            kind: OutboxOperationKind.documentCreate,
            remoteDataSource: documents,
            stagingStore: fileStore,
            draftRepository: draftRepository,
            eventBus: eventBus,
          ),
          AttachmentOutboxHandler(
            remoteDataSource: attachments,
            stagingStore: fileStore,
            draftRepository: draftRepository,
            eventBus: eventBus,
          ),
          DocumentOutboxHandler(
            kind: OutboxOperationKind.documentComplete,
            remoteDataSource: documents,
            stagingStore: fileStore,
            draftRepository: draftRepository,
            eventBus: eventBus,
          ),
        ],
        contextReader: () => const OutboxExecutionContext(
          accountId: '42',
          warehouseId: 8,
          permissionStamp: 'all@1',
          allowedKinds: {
            OutboxOperationKind.documentCreate,
            OutboxOperationKind.attachmentUpload,
            OutboxOperationKind.documentComplete,
          },
        ),
        delay: (_) async {},
      );

      final report = await executor.execute(
        const OutboxReview(
          operationIds: {
            'create',
            'upload-attachment-request-1',
            'upload-attachment-request-2',
            'complete',
          },
          accountId: '42',
          warehouseId: 8,
          permissionStamp: 'all@1',
        ),
      );

      expect(report.failure, isNull);
      expect(report.succeededOperationIds, [
        'create',
        'upload-attachment-request-1',
        'upload-attachment-request-2',
        'complete',
      ]);
      expect(chainEvents, [
        'create:document-request-1',
        'upload:attachment-request-1:91',
        'upload:attachment-request-2:91',
        'complete:91',
      ]);
    },
  );

  test(
    'missing staged file is permanent validation and never uploads',
    () async {
      stagingStore.prepareResult = const FailureResult(
        ValidationFailure(message: 'Staged attachment is missing.'),
      );
      final handler = _handler(
        dataSource,
        stagingStore,
        draftRepository,
        eventBus,
      );

      final result = await handler.execute(
        _operation(),
        dependencyOutputs: {
          'create-document-request-1': OutboxOperationOutput(
            version: 1,
            data: {'documentId': 91},
          ),
        },
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(dataSource.uploads, isEmpty);
      expect(stagingStore.rebindCalls, isEmpty);
      expect(stagingStore.removeCalls, isEmpty);
    },
  );

  test('hash or size changes are rejected before upload', () async {
    stagingStore.staged = _staged(fileSize: 4, sha256: 'changed-hash');
    final handler = _handler(
      dataSource,
      stagingStore,
      draftRepository,
      eventBus,
    );

    final result = await handler.execute(
      _operation(),
      dependencyOutputs: _createDependencyOutput(),
    );

    expect(result.failureOrNull, isA<ValidationFailure>());
    expect(dataSource.uploads, isEmpty);
    expect(stagingStore.removeCalls, isEmpty);
  });

  test('server validation preserves the staged file and draft', () async {
    dataSource.uploadResult = const FailureResult(
      ValidationFailure(message: 'attachment type rejected'),
    );
    final handler = _handler(
      dataSource,
      stagingStore,
      draftRepository,
      eventBus,
    );

    final result = await handler.execute(
      _operation(),
      dependencyOutputs: _createDependencyOutput(),
    );

    expect(result.failureOrNull, isA<ValidationFailure>());
    expect(stagingStore.removeCalls, isEmpty);
    expect(draftRepository.deletedDraftIds, isEmpty);
    expect(events, isEmpty);
  });

  test(
    'unknown result keeps staged evidence for status-first replay',
    () async {
      dataSource.uploadResult = const FailureResult(
        UnknownFailure(message: 'upload response was lost'),
      );
      final handler = _handler(
        dataSource,
        stagingStore,
        draftRepository,
        eventBus,
      );

      final result = await handler.execute(
        _operation(requiresStatusProbe: true),
        dependencyOutputs: {
          'create-document-request-1': OutboxOperationOutput(
            version: 1,
            data: {'documentId': 91},
          ),
        },
      );

      expect(result.failureOrNull, isA<UnknownFailure>());
      expect(dataSource.uploads.single.requestId, 'attachment-request-1');
      expect(stagingStore.rebindCalls, hasLength(1));
      expect(stagingStore.removeCalls, isEmpty);
      expect(draftRepository.deletedDraftIds, isEmpty);
    },
  );

  test(
    'network failure keeps real rebound staging for process-recreated retry',
    () async {
      final root = await Directory.systemTemp.createTemp('rims_outbox_upload_');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}${Platform.pathSeparator}proof.pdf');
      await source.writeAsBytes([1, 2, 3]);
      FileAttachmentStagingStore createStore() => FileAttachmentStagingStore(
        rootDirectory: () async => root,
        idFactory: () => 'attachment-request-1',
        thumbnailBuilder: (_, _) async => null,
      );
      final fileStore = createStore();
      final stagedResult = await fileStore.stage(
        userId: '42',
        binding: AttachmentBinding.documentDraft('draft-1'),
        selection: SelectedAttachmentSource(
          path: source.path,
          originalName: 'proof.pdf',
          mimeType: 'application/pdf',
          fileSize: 3,
        ),
        existingCount: 0,
      );
      final staged = (stagedResult as Success<StagedAttachment>).data;
      dataSource.uploadResult = const FailureResult(NetworkFailure());
      final handler = AttachmentOutboxHandler(
        remoteDataSource: dataSource,
        stagingStore: fileStore,
        draftRepository: draftRepository,
        eventBus: eventBus,
      );

      final result = await handler.execute(
        _operation(payload: {..._payload(), 'expectedSha256': staged.sha256}),
        dependencyOutputs: _createDependencyOutput(),
      );

      expect(result.failureOrNull, isA<NetworkFailure>());
      final recoveredResult = await createStore().loadStaged(
        userId: '42',
        requestId: 'attachment-request-1',
      );
      final recovered = (recoveredResult as Success<StagedAttachment>).data;
      expect(recovered.pending.binding, AttachmentBinding.document(91));
      expect(await File(recovered.pending.stagedPath).readAsBytes(), [1, 2, 3]);
      expect(dataSource.uploadedBytes.single, [1, 2, 3]);
    },
  );

  test(
    'recreated standalone outbox cleans only after success and never uploads twice',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'rims_standalone_outbox_upload_',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}${Platform.pathSeparator}proof.pdf');
      await source.writeAsBytes([1, 2, 3]);
      FileAttachmentStagingStore createStore() => FileAttachmentStagingStore(
        rootDirectory: () async => root,
        idFactory: () => 'standalone-request-1',
        thumbnailBuilder: (_, _) async => null,
      );
      final originalStore = createStore();
      final staged = (await originalStore.stage(
        userId: '42',
        binding: AttachmentBinding.document(91),
        selection: SelectedAttachmentSource(
          path: source.path,
          originalName: 'proof.pdf',
          mimeType: 'application/pdf',
          fileSize: 3,
        ),
        existingCount: 0,
      )).successData;
      final repository = MemoryOutboxRepository(
        stateMachine: OutboxStateMachine(),
      );
      const reviewStamp = '42\u00008\u0000file@1';
      final operation = OutboxOperation(
        operationId: 'attachment-upload-standalone-request-1',
        idempotencyKey: 'standalone-request-1',
        accountId: '42',
        warehouseId: 8,
        kind: OutboxOperationKind.attachmentUpload,
        payload: {
          'version': 1,
          'requestId': 'standalone-request-1',
          'expectedSize': staged.pending.fileSize,
          'expectedSha256': staged.sha256,
        },
        state: OutboxState.queued,
        createdAt: DateTime.utc(2026, 7, 13),
        confirmedAt: DateTime.utc(2026, 7, 13),
        reviewStamp: reviewStamp,
        requiresStatusProbe: true,
      );
      expect(
        await repository.enqueueGraph(OutboxGraph(operations: [operation])),
        isA<Success<Object?>>(),
      );

      final recreatedStore = createStore();
      final uploads = _ChainAttachmentsDataSource([]);
      final coordinator = OutboxCleanupCoordinator(
        repository: repository,
        stagingStore: recreatedStore,
        draftRepository: draftRepository,
        eventBus: eventBus,
      );
      var terminalWasPersistedBeforeCleanup = false;
      final executor = OutboxExecutor(
        repository: repository,
        networkStatusService: const _OnlineNetworkStatusService(),
        statusDataSource: const _AbsentStatusDataSource(),
        handlers: [
          AttachmentOutboxHandler(
            remoteDataSource: uploads,
            stagingStore: recreatedStore,
            draftRepository: draftRepository,
            eventBus: eventBus,
          ),
        ],
        contextReader: () => const OutboxExecutionContext(
          accountId: '42',
          warehouseId: 8,
          permissionStamp: 'file@1',
          allowedKinds: {OutboxOperationKind.attachmentUpload},
        ),
        delay: (_) async {},
        onSuccessPersisted: (accountId) async {
          final persisted = (await repository.list(accountId)).successData;
          final intents = (await repository.listCleanupIntents(
            accountId,
          )).successData;
          terminalWasPersistedBeforeCleanup =
              persisted.single.state == OutboxState.succeeded &&
              intents.single.operationId == operation.operationId;
          await coordinator.run(accountId);
        },
      );
      const review = OutboxReview(
        operationIds: {'attachment-upload-standalone-request-1'},
        accountId: '42',
        warehouseId: 8,
        permissionStamp: 'file@1',
      );

      final report = await executor.execute(review);
      final repeated = await executor.execute(review);

      expect(report.failure, isNull);
      expect(report.succeededOperationIds, [operation.operationId]);
      expect(repeated.failure, isNull);
      expect(repeated.succeededOperationIds, isEmpty);
      expect(terminalWasPersistedBeforeCleanup, isTrue);
      expect(uploads.events, ['upload:standalone-request-1:91']);
      expect(
        (await recreatedStore.loadStaged(
          userId: '42',
          requestId: 'standalone-request-1',
        )).failureOrNull,
        isA<ValidationFailure>(),
      );
      expect((await repository.listCleanupIntents('42')).successData, isEmpty);
    },
  );

  test(
    'draft attachment rejects cleanup ownership reserved for lifecycle',
    () async {
      final handler = _handler(
        dataSource,
        stagingStore,
        draftRepository,
        eventBus,
      );

      final result = await handler.execute(
        _operation(
          payload: {
            ..._payload(),
            'cleanup': const {
              'draftId': 'draft-1',
              'attachmentRequestIds': [
                'attachment-request-1',
                'attachment-request-2',
              ],
            },
          },
        ),
        dependencyOutputs: {
          'create-document-request-1': OutboxOperationOutput(
            version: 1,
            data: {'documentId': 91},
          ),
        },
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(dataSource.uploads, isEmpty);
      expect(stagingStore.removeCalls, isEmpty);
      expect(draftRepository.deletedDraftIds, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<GlobalRefreshRequestedEvent>(), isEmpty);
    },
  );

  test(
    'draft upload strictly validates its single create dependency output',
    () async {
      final handler = _handler(
        dataSource,
        stagingStore,
        draftRepository,
        eventBus,
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
          'parent': OutboxOperationOutput(version: 1, data: {'documentId': 0}),
        },
        {
          'parent': OutboxOperationOutput(
            version: 1,
            data: {'attachmentId': 5, 'documentId': 91, 'extra': true},
          ),
        },
        {
          'parent': OutboxOperationOutput(
            version: 1,
            data: {'attachmentId': 0, 'documentId': 91},
          ),
        },
        {
          'parent': OutboxOperationOutput(
            version: 1,
            data: {'documentId': 91, 'operationKind': 'document_complete'},
          ),
        },
        {'parent-a': valid, 'parent-b': valid},
      ];

      for (final outputs in malformed) {
        final result = await handler.execute(
          _operation(),
          dependencyOutputs: outputs,
        );
        expect(result.failureOrNull, isA<ValidationFailure>());
      }
      expect(dataSource.uploads, isEmpty);
    },
  );
}

AttachmentOutboxHandler _handler(
  AttachmentBytesRemoteDataSource dataSource,
  OutboxAttachmentUploadStagingStore stagingStore,
  DocumentDraftRepository draftRepository,
  AppEventBus eventBus,
) => AttachmentOutboxHandler(
  remoteDataSource: dataSource,
  stagingStore: stagingStore,
  draftRepository: draftRepository,
  eventBus: eventBus,
);

Map<String, Object?> _payload() => const {
  'version': 1,
  'requestId': 'attachment-request-1',
  'expectedSize': 3,
  'expectedSha256': _stableSha256,
  'localAggregateId': 'draft-1',
};

Map<String, Object?> _createDocumentPayload() => const {
  'version': 1,
  'localAggregateId': 'draft-1',
  'attachmentRequestIds': ['attachment-request-1', 'attachment-request-2'],
  'request': {
    'docType': 1,
    'typeLabel': 'Purchase',
    'requestId': 'document-request-1',
    'lines': [
      {
        'productId': 7,
        'productName': 'Widget',
        'quantity': 3,
        'retailPrice': 12.5,
      },
    ],
    'remark': 'serial attachment chain',
  },
};

const _stableSha256 =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

OutboxOperation _operation({
  Map<String, Object?>? payload,
  bool requiresStatusProbe = false,
}) => OutboxOperation(
  operationId: 'upload-attachment-request-1',
  idempotencyKey: 'attachment-request-1',
  accountId: '42',
  warehouseId: 8,
  kind: OutboxOperationKind.attachmentUpload,
  payload: payload ?? _payload(),
  state: OutboxState.queued,
  createdAt: DateTime.utc(2026, 7, 13),
  requiresStatusProbe: requiresStatusProbe,
);

Map<String, OutboxOperationOutput> _createDependencyOutput() => {
  'create-document-request-1': OutboxOperationOutput(
    version: 1,
    data: {'documentId': 91},
  ),
};

StagedAttachment _staged({int fileSize = 3, String sha256 = _stableSha256}) =>
    StagedAttachment(
      pending: PendingAttachment(
        requestId: 'attachment-request-1',
        binding: AttachmentBinding.document(91),
        stagedPath: r'C:\owned\staged\attachment-request-1.pdf',
        originalName: 'proof.pdf',
        mimeType: 'application/pdf',
        fileSize: fileSize,
      ),
      thumbnailPath: null,
      createdAt: DateTime.utc(2026, 7, 13),
      sha256: sha256,
    );

final class _SubmissionStagingStore
    implements OutboxAttachmentUploadStagingStore {
  StagedAttachment staged = _staged();
  Result<AttachmentUploadSnapshot>? prepareResult;
  final List<_PrepareCall> prepareCalls = [];
  final List<List<String>> removeCalls = [];
  final List<_RebindCall> rebindCalls = [];

  @override
  Future<Result<AttachmentUploadSnapshot>> prepareUploadSnapshot({
    required String userId,
    required String requestId,
    required int expectedSize,
    required String expectedSha256,
    required String? localAggregateId,
    required int? documentId,
  }) async {
    prepareCalls.add(_PrepareCall(userId: userId, requestId: requestId));
    if (prepareResult case final result?) return result;
    if (staged.pending.fileSize != expectedSize ||
        staged.sha256 != expectedSha256) {
      return const FailureResult(
        ValidationFailure(message: 'Staged attachment changed after review.'),
      );
    }
    if (localAggregateId == null || documentId == null) {
      return const FailureResult(
        ValidationFailure(message: 'Missing draft attachment dependency.'),
      );
    }
    rebindCalls.add(
      _RebindCall(
        userId: userId,
        localAggregateId: localAggregateId,
        documentId: documentId,
        requestIds: [requestId],
      ),
    );
    staged = StagedAttachment(
      pending: PendingAttachment(
        requestId: staged.pending.requestId,
        binding: AttachmentBinding.document(documentId),
        stagedPath: staged.pending.stagedPath,
        originalName: staged.pending.originalName,
        mimeType: staged.pending.mimeType,
        fileSize: staged.pending.fileSize,
      ),
      thumbnailPath: staged.thumbnailPath,
      createdAt: staged.createdAt,
      sha256: staged.sha256,
    );
    return Success(
      AttachmentUploadSnapshot(pending: staged.pending, bytes: const [1, 2, 3]),
    );
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
}

final class _PrepareCall {
  const _PrepareCall({required this.userId, required this.requestId});

  final String userId;
  final String requestId;
}

final class _AttachmentsDataSource implements AttachmentBytesRemoteDataSource {
  Result<AttachmentModel> uploadResult = Success(
    AttachmentModel(
      id: 5,
      businessType: 'doc_attachment',
      businessId: 91,
      fileUrl: '/uploads/proof.pdf',
      originalName: 'proof.pdf',
      fileSize: 3,
      mimeType: 'application/pdf',
      fileHash: 'stable-hash',
      isPublic: false,
      createdBy: 42,
      uploadedAt: DateTime.utc(2026, 7, 13),
      position: 0,
    ),
  );
  final List<PendingAttachment> uploads = [];
  final List<List<int>> uploadedBytes = [];

  @override
  Future<Result<AttachmentModel>> uploadBytes(
    PendingAttachment pending, {
    required List<int> bytes,
    required void Function(int sent, int total) onProgress,
    required TransferCancellation cancellation,
  }) async {
    uploads.add(pending);
    uploadedBytes.add(List<int>.of(bytes));
    return uploadResult;
  }
}

final class _ChainAttachmentsDataSource
    implements AttachmentBytesRemoteDataSource {
  _ChainAttachmentsDataSource(this.events);

  final List<String> events;
  int _nextId = 10;

  @override
  Future<Result<AttachmentModel>> uploadBytes(
    PendingAttachment pending, {
    required List<int> bytes,
    required void Function(int sent, int total) onProgress,
    required TransferCancellation cancellation,
  }) async {
    events.add('upload:${pending.requestId}:${pending.binding.businessId}');
    return Success(
      AttachmentModel(
        id: _nextId++,
        businessType: pending.binding.businessType,
        businessId: pending.binding.businessId,
        fileUrl: '/uploads/${pending.originalName}',
        originalName: pending.originalName,
        fileSize: bytes.length,
        mimeType: pending.mimeType,
        fileHash: 'hash',
        isPublic: false,
        createdBy: 42,
        uploadedAt: DateTime.utc(2026, 7, 13),
        position: 0,
      ),
    );
  }
}

final class _ChainDocumentsDataSource implements DocumentsRemoteDataSource {
  _ChainDocumentsDataSource(this.events);

  final List<String> events;

  @override
  Future<Result<DocumentRecordModel>> createDocument(
    CreateDocumentRequest request,
  ) async {
    events.add('create:${request.requestId}');
    return const Success(
      DocumentRecordModel(
        id: 91,
        docType: 1,
        title: 'Purchase',
        number: 'DOC-91',
        status: 'draft',
        productName: 'Widget',
        quantity: 3,
        remark: '',
        createdAt: '2026-07-13T00:00:00Z',
      ),
    );
  }

  @override
  Future<Result<void>> completeDocument(int id, {String? requestId}) async {
    events.add('complete:$id');
    return const Success(null);
  }

  @override
  Future<Result<void>> confirmDocument(int id, {String? requestId}) =>
      throw UnimplementedError();

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

  @override
  Future<Result<void>> settleDocument(int id, {String? requestId}) =>
      throw UnimplementedError();
}

final class _UnexpectedStatusDataSource
    implements OperationStatusRemoteDataSource {
  const _UnexpectedStatusDataSource();

  @override
  Future<Result<OperationStatus>> loadStatus({
    required String key,
    required String scope,
  }) => throw StateError('Status probe was not expected.');
}

final class _AbsentStatusDataSource implements OperationStatusRemoteDataSource {
  const _AbsentStatusDataSource();

  @override
  Future<Result<OperationStatus>> loadStatus({
    required String key,
    required String scope,
  }) async => const FailureResult(NotFoundFailure());
}

final class _OnlineNetworkStatusService implements NetworkStatusService {
  const _OnlineNetworkStatusService();

  @override
  Stream<NetworkReachability> get changes => const Stream.empty();

  @override
  NetworkReachability get current => NetworkReachability.online;

  @override
  Future<void> dispose() async {}

  @override
  void markOnlineFromRequest() {}

  @override
  Future<NetworkReachability> verify() async => NetworkReachability.online;
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
  Future<DocumentDraft?> load({
    required String accountId,
    required String draftId,
  }) => throw UnimplementedError();

  @override
  Future<List<DocumentDraft>> list(String accountId) =>
      throw UnimplementedError();

  @override
  Future<void> prune() => throw UnimplementedError();

  @override
  Future<Result<DocumentDraft>> save(
    DocumentDraft draft, {
    required int expectedVersion,
  }) => throw UnimplementedError();
}

extension on Result<dynamic> {
  Failure? get failureOrNull => switch (this) {
    FailureResult<Object?>(:final failure) => failure,
    _ => null,
  };
}

extension<T> on Result<T> {
  T get successData => (this as Success<T>).data;
}
