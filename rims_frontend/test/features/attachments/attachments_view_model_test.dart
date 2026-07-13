import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/attachments/data/services/attachment_share_service.dart';
import 'package:rims_frontend/features/attachments/domain/entities/attachment.dart';
import 'package:rims_frontend/features/attachments/domain/repositories/attachments_repository.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_picker.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_staging_store.dart';
import 'package:rims_frontend/features/attachments/presentation/view_models/attachments_view_model.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/repositories/outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_executor.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_state_machine.dart';

void main() {
  test('load exposes empty, success, and error states', () async {
    final repository = _FakeRepository();
    final viewModel = _viewModel(repository: repository);

    await viewModel.load();
    expect(viewModel.attachments, isEmpty);
    expect(viewModel.errorMessage, isNull);

    repository.listResult = const FailureResult(NetworkFailure());
    await viewModel.load();
    expect(viewModel.errorMessage, 'Network unavailable');
  });

  test('pick stages and uploads with stable progress state', () async {
    final repository = _FakeRepository();
    final staging = _FakeStaging();
    final viewModel = _viewModel(repository: repository, staging: staging);

    await viewModel.pickAndUpload(AttachmentPickSource.camera);

    expect(repository.uploadedRequestIds, ['stable-request']);
    expect(viewModel.attachments.single.id, 7);
    expect(viewModel.queue, isEmpty);
    expect(staging.removedRequestIds, ['stable-request']);
  });

  test('one-flight guard ignores a second picker action', () async {
    final repository = _FakeRepository()..holdUpload = true;
    final picker = _FakePicker();
    final viewModel = _viewModel(repository: repository, picker: picker);

    final first = viewModel.pickAndUpload(AttachmentPickSource.camera);
    await Future<void>.delayed(Duration.zero);
    await viewModel.pickAndUpload(AttachmentPickSource.gallery);
    expect(picker.pickCalls, 1);

    repository.releaseUpload();
    await first;
  });

  test('cancel and retry reuse the same request id', () async {
    final repository = _FakeRepository()
      ..uploadResult = const FailureResult(NetworkFailure());
    final viewModel = _viewModel(repository: repository);

    await viewModel.pickAndUpload(AttachmentPickSource.file);
    expect(viewModel.queue.single.state, AttachmentTransferState.failed);
    await viewModel.retry('stable-request');

    expect(repository.uploadedRequestIds, ['stable-request', 'stable-request']);
    viewModel.cancel('stable-request');
    expect(viewModel.queue.single.state, AttachmentTransferState.cancelled);
  });

  test(
    'offline upload requires confirmation and queues one stable snapshot',
    () async {
      final repository = _FakeRepository()
        ..uploadResult = const FailureResult(NetworkFailure());
      final outbox = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
      final viewModel = _viewModel(repository: repository, outbox: outbox);

      await viewModel.pickAndUpload(AttachmentPickSource.file);

      expect((await outbox.list('3')).successData, isEmpty);
      expect(
        viewModel.offlineUploadReviewFor('stable-request')?.originalName,
        'receipt.pdf',
      );
      expect(viewModel.offlineUploadReviewFor('stable-request')?.fileSize, 128);
      expect(await viewModel.confirmOfflineUpload('stable-request'), isTrue);
      expect(await viewModel.confirmOfflineUpload('stable-request'), isFalse);

      final queued = (await outbox.list('3')).successData;
      expect(queued, hasLength(1));
      expect(queued.single.kind, OutboxOperationKind.attachmentUpload);
      expect(queued.single.idempotencyKey, 'stable-request');
      expect(queued.single.payload['expectedSha256'], 'stable-hash');
      expect(queued.single.requiresStatusProbe, isFalse);
    },
  );

  test(
    'initially denied attachment upload never offers offline queue',
    () async {
      final repository = _FakeRepository()
        ..uploadResult = const FailureResult(NetworkFailure());
      final outbox = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
      final viewModel = _viewModel(
        repository: repository,
        outbox: outbox,
        allowedOutboxKindsReader: () => const {
          OutboxOperationKind.documentCreate,
        },
      );

      await viewModel.pickAndUpload(AttachmentPickSource.file);

      expect(viewModel.offlineUploadReviewFor('stable-request'), isNull);
      expect(viewModel.offlineUploadFailure, isA<AuthorizationFailure>());
      expect((await outbox.list('3')).successData, isEmpty);
    },
  );

  test('attachment permission revoked after offer prevents enqueue', () async {
    var allowedKinds = const {OutboxOperationKind.attachmentUpload};
    final repository = _FakeRepository()
      ..uploadResult = const FailureResult(NetworkFailure());
    final outbox = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
    final viewModel = _viewModel(
      repository: repository,
      outbox: outbox,
      allowedOutboxKindsReader: () => allowedKinds,
    );

    await viewModel.pickAndUpload(AttachmentPickSource.file);
    expect(viewModel.offlineUploadReviewFor('stable-request'), isNotNull);
    allowedKinds = const {OutboxOperationKind.documentCreate};

    expect(await viewModel.confirmOfflineUpload('stable-request'), isFalse);
    expect(viewModel.offlineUploadFailure, isA<AuthorizationFailure>());
    expect((await outbox.list('3')).successData, isEmpty);
  });

  test(
    'permission revoked while staged snapshot loads prevents graph enqueue',
    () async {
      var generation = 1;
      var context = const OutboxExecutionContext(
        accountId: '3',
        warehouseId: 11,
        permissionStamp: 'files@1',
        allowedKinds: {OutboxOperationKind.attachmentUpload},
      );
      final repository = _FakeRepository()
        ..uploadResult = const FailureResult(NetworkFailure());
      final staging = _FakeStaging()
        ..loadStagedCompleter = Completer<Result<StagedAttachment>>();
      final outbox = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
      final viewModel = _viewModel(
        repository: repository,
        staging: staging,
        outbox: outbox,
        outboxContextReader: () => context,
        outboxContextGenerationReader: () => generation,
      );

      await viewModel.pickAndUpload(AttachmentPickSource.file);
      final confirming = viewModel.confirmOfflineUpload('stable-request');
      await staging.loadStagedStarted.future;
      generation += 1;
      context = const OutboxExecutionContext(
        accountId: '3',
        warehouseId: 11,
        permissionStamp: 'files@2',
        allowedKinds: {OutboxOperationKind.documentCreate},
      );
      staging.loadStagedCompleter!.complete(Success(_staged()));

      expect(await confirming, isFalse);
      expect(viewModel.offlineUploadFailure, isA<AuthorizationFailure>());
      expect((await outbox.list('3')).successData, isEmpty);
      expect(staging.removedRequestIds, isEmpty);
      expect(viewModel.offlineUploadReviewFor('stable-request'), isNotNull);
    },
  );

  test(
    'account or warehouse context change while hash loads keeps staged evidence',
    () async {
      var generation = 7;
      var context = const OutboxExecutionContext(
        accountId: '3',
        warehouseId: 11,
        permissionStamp: 'files@1',
        allowedKinds: {OutboxOperationKind.attachmentUpload},
      );
      final repository = _FakeRepository()
        ..uploadResult = const FailureResult(NetworkFailure());
      final staging = _FakeStaging()
        ..loadStagedCompleter = Completer<Result<StagedAttachment>>();
      final outbox = MemoryOutboxRepository(stateMachine: OutboxStateMachine());
      final viewModel = _viewModel(
        repository: repository,
        staging: staging,
        outbox: outbox,
        outboxContextReader: () => context,
        outboxContextGenerationReader: () => generation,
      );

      await viewModel.pickAndUpload(AttachmentPickSource.file);
      final confirming = viewModel.confirmOfflineUpload('stable-request');
      await staging.loadStagedStarted.future;
      generation += 1;
      context = const OutboxExecutionContext(
        accountId: '4',
        warehouseId: 12,
        permissionStamp: 'files@2',
        allowedKinds: {OutboxOperationKind.attachmentUpload},
      );
      staging.loadStagedCompleter!.complete(Success(_staged()));

      expect(await confirming, isFalse);
      expect(viewModel.offlineUploadFailure, isA<StateFailure>());
      expect((await outbox.list('3')).successData, isEmpty);
      expect((await outbox.list('4')).successData, isEmpty);
      expect(staging.removedRequestIds, isEmpty);
      expect(viewModel.offlineUploadReviewFor('stable-request'), isNotNull);
    },
  );

  test(
    'unknown upload queues status-first but validation remains immediate',
    () async {
      final unknownOutbox = MemoryOutboxRepository(
        stateMachine: OutboxStateMachine(),
      );
      final unknownRepository = _FakeRepository()
        ..uploadResult = const FailureResult(TransportUnknownFailure());
      final unknown = _viewModel(
        repository: unknownRepository,
        outbox: unknownOutbox,
      );
      await unknown.pickAndUpload(AttachmentPickSource.file);
      expect(await unknown.confirmOfflineUpload('stable-request'), isTrue);
      expect(
        (await unknownOutbox.list('3')).successData.single.requiresStatusProbe,
        isTrue,
      );

      final rejectedOutbox = MemoryOutboxRepository(
        stateMachine: OutboxStateMachine(),
      );
      final rejectedRepository = _FakeRepository()
        ..uploadResult = const FailureResult(ValidationFailure());
      final rejected = _viewModel(
        repository: rejectedRepository,
        outbox: rejectedOutbox,
      );
      await rejected.pickAndUpload(AttachmentPickSource.file);
      expect(rejected.offlineUploadReviewFor('stable-request'), isNull);
      expect((await rejectedOutbox.list('3')).successData, isEmpty);
    },
  );

  test(
    'recovers interrupted staging and resumes after background cancellation',
    () async {
      final repository = _FakeRepository()
        ..uploadResult = const FailureResult(CancellationFailure());
      final staging = _FakeStaging()..recovered = [_staged()];
      final viewModel = _viewModel(repository: repository, staging: staging);

      await viewModel.recoverInterrupted();
      expect(viewModel.queue.single.state, AttachmentTransferState.interrupted);
      viewModel.pause();
      await viewModel.resume();

      expect(repository.uploadedRequestIds, ['stable-request']);
    },
  );

  test('download shares the authenticated local file', () async {
    final repository = _FakeRepository();
    final share = _FakeShare();
    final viewModel = _viewModel(repository: repository, share: share);

    await viewModel.downloadAndShare(_attachment());

    expect(share.paths, ['/support/receipt.pdf']);
  });

  test(
    'delete, replace, and reorder roll back optimistic state on failure',
    () async {
      final repository = _FakeRepository()
        ..listResult = Success(
          PageData(
            items: [_attachment(), _attachment(id: 8, position: 1)],
            total: 2,
            page: 1,
            pageSize: 20,
          ),
        );
      final viewModel = _viewModel(repository: repository);
      await viewModel.load();

      repository.deleteResult = const FailureResult(NetworkFailure());
      await viewModel.delete(_attachment());
      expect(viewModel.attachments.map((item) => item.id), [7, 8]);

      repository.reorderResult = const FailureResult(ConflictFailure());
      await viewModel.reorder([8, 7]);
      expect(viewModel.attachments.map((item) => item.id), [7, 8]);

      repository.replaceResult = const FailureResult(NetworkFailure());
      await viewModel.replace(_attachment(), AttachmentPickSource.gallery);
      expect(viewModel.attachments.first.originalName, 'receipt.pdf');
      expect(viewModel.errorMessage, isNotNull);
    },
  );

  test(
    'product synchronization publishes URL and restores after delete failure',
    () async {
      final repository = _FakeRepository()
        ..listResult = Success(
          PageData(items: [_attachment()], total: 1, page: 1, pageSize: 20),
        )
        ..deleteResult = const FailureResult(NetworkFailure());
      final synchronized = <String>[];
      final viewModel = AttachmentsViewModel(
        repository: repository,
        picker: _FakePicker(),
        stagingStore: _FakeStaging(),
        shareService: _FakeShare(),
        binding: AttachmentBinding.productImage(42),
        userId: '3',
        onAttachmentPublished: (attachment) async {
          synchronized.add('publish:${attachment.downloadUri}');
          return const Success(null);
        },
        beforeAttachmentDelete: (attachment) async {
          synchronized.add('clear');
          return const Success(null);
        },
        restoreAfterDeleteFailure: (attachment) async {
          synchronized.add('restore:${attachment.downloadUri}');
          return const Success(null);
        },
      );
      await viewModel.load();
      await viewModel.pickAndUpload(AttachmentPickSource.gallery);
      await viewModel.delete(_attachment());
      await Future<void>.delayed(Duration.zero);

      expect(synchronized.first, startsWith('publish:'));
      expect(synchronized, contains('clear'));
      expect(synchronized.last, startsWith('restore:'));
      expect(viewModel.attachments, isNotEmpty);
    },
  );
}

AttachmentsViewModel _viewModel({
  _FakeRepository? repository,
  _FakePicker? picker,
  _FakeStaging? staging,
  _FakeShare? share,
  OutboxRepository? outbox,
  Set<OutboxOperationKind> Function()? allowedOutboxKindsReader,
  OutboxExecutionContext? Function()? outboxContextReader,
  int Function()? outboxContextGenerationReader,
}) => AttachmentsViewModel(
  repository: repository ?? _FakeRepository(),
  picker: picker ?? _FakePicker(),
  stagingStore: staging ?? _FakeStaging(),
  shareService: share ?? _FakeShare(),
  binding: AttachmentBinding.document(42),
  userId: '3',
  warehouseId: 11,
  outboxRepository: outbox,
  allowedOutboxKindsReader: allowedOutboxKindsReader,
  outboxContextReader: outboxContextReader,
  outboxContextGenerationReader: outboxContextGenerationReader,
);

Attachment _attachment({int id = 7, int position = 0}) => Attachment(
  id: id,
  binding: AttachmentBinding.document(42),
  downloadUri: Uri.parse('http://localhost:8080/api/v1/files/$id/download'),
  originalName: 'receipt.pdf',
  fileSize: 128,
  mimeType: 'application/pdf',
  fileHash: 'hash$id',
  isPublic: false,
  createdBy: 3,
  uploadedAt: DateTime.utc(2026, 7, 13),
  position: position,
);

StagedAttachment _staged() => StagedAttachment(
  pending: PendingAttachment(
    requestId: 'stable-request',
    binding: AttachmentBinding.document(42),
    stagedPath: '/support/staged.pdf',
    originalName: 'receipt.pdf',
    mimeType: 'application/pdf',
    fileSize: 128,
  ),
  thumbnailPath: null,
  createdAt: DateTime.utc(2026, 7, 13),
  sha256: 'stable-hash',
);

final class _FakeRepository implements AttachmentsRepository {
  Result<PageData<Attachment>> listResult = Success(
    PageData(items: [], total: 0, page: 1, pageSize: 20),
  );
  Result<Attachment> uploadResult = Success(_attachment());
  Result<Attachment> replaceResult = Success(_attachment());
  Result<void> deleteResult = const Success(null);
  Result<void> reorderResult = const Success(null);
  bool holdUpload = false;
  final List<String> uploadedRequestIds = [];
  final _release = <Completer<void>>[];

  void releaseUpload() {
    for (final completer in _release) {
      completer.complete();
    }
    _release.clear();
  }

  @override
  Future<Result<PageData<Attachment>>> list({
    required AttachmentBinding binding,
    int page = 1,
  }) async => listResult;

  @override
  Future<Result<Attachment>> upload(
    PendingAttachment pending, {
    required TransferProgress onProgress,
    required TransferCancellation cancellation,
  }) async {
    uploadedRequestIds.add(pending.requestId);
    onProgress(64, 128);
    if (holdUpload) {
      final completer = Completer<void>();
      _release.add(completer);
      await completer.future;
    }
    return cancellation.isCancelled
        ? const FailureResult(CancellationFailure())
        : uploadResult;
  }

  @override
  Future<Result<Attachment>> replace(
    Attachment existing,
    PendingAttachment pending, {
    required TransferProgress onProgress,
    required TransferCancellation cancellation,
  }) async => replaceResult;

  @override
  Future<Result<void>> reorder(
    AttachmentBinding binding,
    List<int> fileIds,
  ) async => reorderResult;

  @override
  Future<Result<String>> download(Attachment attachment) async =>
      const Success('/support/receipt.pdf');

  @override
  Future<Result<void>> delete(int id) async => deleteResult;
}

final class _FakePicker implements AttachmentPicker {
  int pickCalls = 0;

  @override
  Future<Result<SelectedAttachmentSource?>> pick(
    AttachmentPickSource source,
  ) async {
    pickCalls++;
    return const Success(
      SelectedAttachmentSource(
        path: '/tmp/source.pdf',
        originalName: 'receipt.pdf',
        mimeType: 'application/pdf',
        fileSize: 128,
      ),
    );
  }

  @override
  Future<Result<List<SelectedAttachmentSource>>> recoverLostData() async =>
      const Success([]);

  @override
  List<SelectedAttachmentSource> takeRecovered() => const [];
}

final class _FakeStaging
    implements AttachmentStagingStore, OutboxAttachmentStagingStore {
  List<StagedAttachment> recovered = [];
  final List<String> removedRequestIds = [];
  Completer<Result<StagedAttachment>>? loadStagedCompleter;
  final Completer<void> loadStagedStarted = Completer<void>();

  @override
  Future<Result<StagedAttachment>> stage({
    required String userId,
    required AttachmentBinding binding,
    required SelectedAttachmentSource selection,
    required int existingCount,
  }) async => Success(_staged());

  @override
  Future<Result<List<StagedAttachment>>> recoverForUser(String userId) async =>
      Success(recovered);

  @override
  Future<Result<void>> remove(String userId, String requestId) async {
    removedRequestIds.add(requestId);
    return const Success(null);
  }

  @override
  Future<Result<void>> cleanupStale({
    required String userId,
    required Duration maxAge,
    Set<String> protectedRequestIds = const {},
  }) async => const Success(null);
  @override
  Future<Result<void>> clearForUser(String userId) async => const Success(null);
  @override
  Future<Result<String>> saveDownload({
    required String userId,
    required String originalName,
    required Uint8List bytes,
  }) async => const Success('/support/download');

  @override
  Future<Result<StagedAttachment>> loadStaged({
    required String userId,
    required String requestId,
  }) async {
    if (!loadStagedStarted.isCompleted) loadStagedStarted.complete();
    return loadStagedCompleter?.future ?? Success(_staged());
  }

  @override
  Future<Result<void>> rebindDocumentDraft({
    required String userId,
    required String localAggregateId,
    required int documentId,
    required List<String> requestIds,
  }) async => const Success(null);

  @override
  Future<Result<void>> removeStagedAttachments({
    required String userId,
    required List<String> requestIds,
  }) async {
    removedRequestIds.addAll(requestIds);
    return const Success(null);
  }
}

extension _SuccessData<T> on Result<T> {
  T get successData => switch (this) {
    Success<T>(:final data) => data,
    FailureResult<T>(:final failure) => throw TestFailure(failure.message),
  };
}

final class _FakeShare implements AttachmentShareService {
  final List<String> paths = [];

  @override
  Future<Result<void>> share({
    required String path,
    required String originalName,
    required String mimeType,
  }) async {
    paths.add(path);
    return const Success(null);
  }
}
