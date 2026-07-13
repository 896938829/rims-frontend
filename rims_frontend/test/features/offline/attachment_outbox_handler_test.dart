import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/events/app_event.dart';
import 'package:rims_frontend/core/events/app_event_bus.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/attachments/data/datasources/attachments_remote_datasource.dart';
import 'package:rims_frontend/features/attachments/data/models/attachment_models.dart';
import 'package:rims_frontend/features/attachments/domain/entities/attachment.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_staging_store.dart';
import 'package:rims_frontend/features/offline/data/services/attachment_outbox_handler.dart';
import 'package:rims_frontend/features/offline/domain/entities/document_draft.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/repositories/document_draft_repository.dart';

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
    expect(stagingStore.loadCalls, isEmpty);
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
    expect(stagingStore.loadCalls, isEmpty);
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

      final result = await handler.execute(_operation());

      expect(result, isA<Success<Object?>>());
      expect(stagingStore.loadCalls, [
        const _LoadCall(userId: '42', requestId: 'attachment-request-1'),
      ]);
      expect(dataSource.uploads.single.requestId, 'attachment-request-1');
      expect(dataSource.uploads.single.binding, AttachmentBinding.document(91));
    },
  );

  test(
    'missing staged file is permanent validation and never uploads',
    () async {
      stagingStore.loadResult = const FailureResult(
        ValidationFailure(message: 'Staged attachment is missing.'),
      );
      final handler = _handler(
        dataSource,
        stagingStore,
        draftRepository,
        eventBus,
      );

      final result = await handler.execute(_operation());

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(dataSource.uploads, isEmpty);
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

    final result = await handler.execute(_operation());

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

    final result = await handler.execute(_operation());

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
      );

      expect(result.failureOrNull, isA<UnknownFailure>());
      expect(dataSource.uploads.single.requestId, 'attachment-request-1');
      expect(stagingStore.removeCalls, isEmpty);
      expect(draftRepository.deletedDraftIds, isEmpty);
    },
  );

  test(
    'terminal success atomically cleans staged graph and draft then refreshes',
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
      );

      expect(result, isA<Success<Object?>>());
      expect(stagingStore.removeCalls, [
        const ['attachment-request-1', 'attachment-request-2'],
      ]);
      expect(draftRepository.deletedDraftIds, ['draft-1']);
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<GlobalRefreshRequestedEvent>(), hasLength(1));
    },
  );
}

AttachmentOutboxHandler _handler(
  AttachmentsRemoteDataSource dataSource,
  OutboxAttachmentStagingStore stagingStore,
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

final class _SubmissionStagingStore implements OutboxAttachmentStagingStore {
  StagedAttachment staged = _staged();
  Result<StagedAttachment>? loadResult;
  final List<_LoadCall> loadCalls = [];
  final List<List<String>> removeCalls = [];

  @override
  Future<Result<StagedAttachment>> loadStaged({
    required String userId,
    required String requestId,
  }) async {
    loadCalls.add(_LoadCall(userId: userId, requestId: requestId));
    return loadResult ?? Success(staged);
  }

  @override
  Future<Result<void>> rebindDocumentDraft({
    required String userId,
    required String localAggregateId,
    required int documentId,
    required List<String> requestIds,
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

final class _LoadCall {
  const _LoadCall({required this.userId, required this.requestId});

  final String userId;
  final String requestId;

  @override
  bool operator ==(Object other) =>
      other is _LoadCall &&
      other.userId == userId &&
      other.requestId == requestId;

  @override
  int get hashCode => Object.hash(userId, requestId);
}

final class _AttachmentsDataSource implements AttachmentsRemoteDataSource {
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

  @override
  Future<Result<AttachmentModel>> upload(
    PendingAttachment pending, {
    required void Function(int sent, int total) onProgress,
    required TransferCancellation cancellation,
  }) async {
    uploads.add(pending);
    return uploadResult;
  }

  @override
  Future<Result<void>> delete(int id) => throw UnimplementedError();

  @override
  Future<Result<Uint8List>> download(int id) => throw UnimplementedError();

  @override
  Future<Result<PageData<AttachmentModel>>> list({
    required AttachmentBinding binding,
    int page = 1,
  }) => throw UnimplementedError();

  @override
  Future<Result<void>> reorder(AttachmentBinding binding, List<int> fileIds) =>
      throw UnimplementedError();

  @override
  Future<Result<AttachmentModel>> replace(
    int id,
    PendingAttachment pending, {
    required void Function(int sent, int total) onProgress,
    required TransferCancellation cancellation,
  }) => throw UnimplementedError();
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

extension on Result<Object?> {
  Failure? get failureOrNull => switch (this) {
    FailureResult<Object?>(:final failure) => failure,
    _ => null,
  };
}
