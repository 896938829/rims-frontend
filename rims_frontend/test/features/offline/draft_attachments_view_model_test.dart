import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/attachments/domain/entities/attachment.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_picker.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_staging_store.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/documents/presentation/view_models/documents_view_model.dart';
import 'package:rims_frontend/features/offline/data/repositories/drift_document_draft_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/offline/domain/entities/document_draft.dart';
import 'package:rims_frontend/features/offline/domain/repositories/document_draft_repository.dart';
import 'package:rims_frontend/features/offline/presentation/view_models/draft_attachments_view_model.dart';
import 'package:rims_frontend/features/offline/presentation/view_models/drafts_view_model.dart';

void main() {
  test(
    'creates stable draft identity before staging and publishes request ids',
    () async {
      final staging = _DraftStaging();
      final changes = <List<String>>[];
      var identityCreated = false;
      final viewModel = DraftAttachmentsViewModel(
        picker: _DraftPicker(),
        stagingStore: staging,
        userId: '7',
        draftIdProvider: () {
          identityCreated = true;
          return 'stable-draft';
        },
        onChanged: (ids) => changes.add(ids),
      );

      await viewModel.pick(AttachmentPickSource.file);

      expect(identityCreated, isTrue);
      expect(staging.bindings.single.localDraftId, 'stable-draft');
      expect(viewModel.staged.map((item) => item.pending.requestId), [
        'request-1',
      ]);
      expect(changes.last, ['request-1']);
    },
  );

  test('reopen recovers only request ids bound to the active draft', () async {
    final staging = _DraftStaging()
      ..recovered = [
        _staged('keep', 'draft-a'),
        _staged('other-draft', 'draft-b'),
        _staged('not-in-record', 'draft-a'),
      ];
    final viewModel = DraftAttachmentsViewModel(
      picker: _DraftPicker(),
      stagingStore: staging,
      userId: '7',
      draftIdProvider: () => 'draft-a',
      onChanged: (_) {},
    );

    await viewModel.recover(['keep']);

    expect(viewModel.staged.map((item) => item.pending.requestId), ['keep']);
  });

  test('late recover for draft A cannot overwrite draft B', () async {
    final recoverA = Completer<Result<List<StagedAttachment>>>();
    final recoverB = Completer<Result<List<StagedAttachment>>>();
    final staging = _DraftStaging(
      recoverResults: [recoverA.future, recoverB.future],
    );
    var draftId = 'draft-a';
    final viewModel = DraftAttachmentsViewModel(
      picker: _DraftPicker(),
      stagingStore: staging,
      userId: '7',
      draftIdProvider: () => draftId,
      onChanged: (_) {},
    );

    final first = viewModel.recover(['a']);
    draftId = 'draft-b';
    final second = viewModel.recover(['b']);
    recoverB.complete(Success([_staged('b', 'draft-b')]));
    await second;
    recoverA.complete(Success([_staged('a', 'draft-a')]));
    await first;

    expect(viewModel.staged.map((item) => item.pending.requestId), ['b']);
  });

  test(
    'picker result after submission starts is ignored before staging',
    () async {
      final picked = Completer<Result<SelectedAttachmentSource?>>();
      final staging = _DraftStaging();
      var canMutate = true;
      var epoch = 0;
      final viewModel = DraftAttachmentsViewModel(
        picker: _DraftPicker(result: picked.future),
        stagingStore: staging,
        userId: '7',
        draftIdProvider: () => 'draft-a',
        canMutate: () => canMutate,
        mutationEpochProvider: () => epoch,
        onChanged: (_) {},
      );

      final pick = viewModel.pick(AttachmentPickSource.file);
      canMutate = false;
      epoch += 1;
      picked.complete(const Success(_selection));
      await pick;

      expect(staging.bindings, isEmpty);
      expect(viewModel.staged, isEmpty);
    },
  );

  test('late stage for old draft is removed instead of published', () async {
    final staged = Completer<Result<StagedAttachment>>();
    final staging = _DraftStaging(stageResult: staged.future);
    final changes = <List<String>>[];
    var draftId = 'draft-a';
    final viewModel = DraftAttachmentsViewModel(
      picker: _DraftPicker(),
      stagingStore: staging,
      userId: '7',
      draftIdProvider: () => draftId,
      onChanged: changes.add,
    );

    final pick = viewModel.pick(AttachmentPickSource.file);
    await staging.stageStarted.future;
    draftId = 'draft-b';
    await viewModel.recover(const []);
    staged.complete(Success(_staged('late-a', 'draft-a')));
    await pick;

    expect(staging.removed, ['late-a']);
    expect(viewModel.staged, isEmpty);
    expect(changes, isEmpty);
  });

  test('stage success after submission epoch changes is removed', () async {
    final staged = Completer<Result<StagedAttachment>>();
    final staging = _DraftStaging(stageResult: staged.future);
    var canMutate = true;
    var epoch = 0;
    final viewModel = DraftAttachmentsViewModel(
      picker: _DraftPicker(),
      stagingStore: staging,
      userId: '7',
      draftIdProvider: () => 'draft-a',
      canMutate: () => canMutate,
      mutationEpochProvider: () => epoch,
      onChanged: (_) {},
    );

    final pick = viewModel.pick(AttachmentPickSource.file);
    await staging.stageStarted.future;
    canMutate = false;
    epoch += 1;
    staged.complete(Success(_staged('late-submit', 'draft-a')));
    await pick;

    expect(staging.removed, ['late-submit']);
    expect(viewModel.staged, isEmpty);
  });

  test('dispose compensates a stage that succeeds late', () async {
    final staged = Completer<Result<StagedAttachment>>();
    final staging = _DraftStaging(stageResult: staged.future);
    final viewModel = DraftAttachmentsViewModel(
      picker: _DraftPicker(),
      stagingStore: staging,
      userId: '7',
      draftIdProvider: () => 'draft-a',
      onChanged: (_) {},
    );

    final pick = viewModel.pick(AttachmentPickSource.file);
    await staging.stageStarted.future;
    viewModel.dispose();
    staged.complete(Success(_staged('late-dispose', 'draft-a')));
    await pick;

    expect(staging.removed, ['late-dispose']);
  });

  test(
    'delayed remove stays busy and reconciles after submission epoch changes',
    () async {
      final removed = Completer<Result<void>>();
      final staging = _DraftStaging(removeResult: removed.future)
        ..recovered = [_staged('remove-me', 'draft-a')];
      final changes = <List<String>>[];
      var canMutate = true;
      var epoch = 0;
      final viewModel = DraftAttachmentsViewModel(
        picker: _DraftPicker(),
        stagingStore: staging,
        userId: '7',
        draftIdProvider: () => 'draft-a',
        canMutate: () => canMutate,
        mutationEpochProvider: () => epoch,
        onChanged: changes.add,
      );
      await viewModel.recover(['remove-me']);

      final remove = viewModel.remove('remove-me');
      await staging.removeStarted.future;

      expect(viewModel.isBusy, isTrue);
      canMutate = false;
      epoch += 1;
      removed.complete(const Success(null));
      await remove;

      expect(viewModel.isBusy, isFalse);
      expect(viewModel.staged, isEmpty);
      expect(staging.recovered, isEmpty);
      expect(changes.last, isEmpty);
    },
  );

  test(
    'late remove for draft A reconciles A without overwriting draft B',
    () async {
      final removed = Completer<Result<void>>();
      final staging = _DraftStaging(removeResult: removed.future)
        ..recovered = [
          _staged('remove-a', 'draft-a'),
          _staged('keep-b', 'draft-b'),
        ];
      final scopedChanges = <(String, List<String>)>[];
      var draftId = 'draft-a';
      final viewModel = DraftAttachmentsViewModel(
        picker: _DraftPicker(),
        stagingStore: staging,
        userId: '7',
        draftIdProvider: () => draftId,
        onChanged: (_) {},
        onChangedForDraft: (id, ids) => scopedChanges.add((id, ids)),
      );
      await viewModel.recover(['remove-a']);

      final remove = viewModel.remove('remove-a');
      await staging.removeStarted.future;
      draftId = 'draft-b';
      await viewModel.recover(['keep-b']);
      removed.complete(const Success(null));
      await remove;

      expect(viewModel.staged.map((item) => item.pending.requestId), [
        'keep-b',
      ]);
      expect(scopedChanges, hasLength(1));
      expect(scopedChanges.single.$1, 'draft-a');
      expect(scopedChanges.single.$2, isEmpty);
    },
  );

  test(
    'disposed pending remove persists A through conflict and leaves B copyable',
    () async {
      final store = MemoryOfflineStore();
      final initialRepository = DriftDocumentDraftRepository(
        store: store,
        now: () => DateTime.utc(2026, 7, 13, 10),
      );
      await initialRepository.save(
        _documentDraft(
          id: 'draft-a',
          attachmentIds: const ['remove-a'],
          remark: 'original',
        ),
        expectedVersion: 0,
      );
      await initialRepository.save(
        _documentDraft(
          id: 'draft-b',
          attachmentIds: const ['keep-b'],
          remark: 'untouched',
        ),
        expectedVersion: 0,
      );
      final repository = _ConflictOnceDraftRepository(initialRepository);
      final removed = Completer<Result<void>>();
      final staging = _DraftStaging(removeResult: removed.future)
        ..recovered = [_staged('remove-a', 'draft-a')];
      final attachments = DraftAttachmentsViewModel(
        picker: _DraftPicker(),
        stagingStore: staging,
        userId: 'account-7',
        draftIdProvider: () => 'draft-a',
        onChanged: (_) {},
        draftRepository: repository,
        draftAccountId: 'account-7',
      );
      await attachments.recover(['remove-a']);

      final remove = attachments.remove('remove-a');
      await staging.removeStarted.future;
      attachments.dispose();
      removed.complete(const Success(null));
      await remove;

      final rebuiltRepository = DriftDocumentDraftRepository(
        store: store,
        now: () => DateTime.utc(2026, 7, 13, 11),
      );
      final documents = DocumentsViewModel(
        draftRepository: rebuiltRepository,
        accountId: 'account-7',
        currentWarehouse: const Warehouse(
          id: 1,
          code: 'WH-1',
          name: 'Warehouse 1',
          isDefault: true,
        ),
      );

      expect(await documents.openDraft('draft-a'), isTrue);
      expect(documents.attachmentStagingIds, isEmpty);
      final persistedA = await rebuiltRepository.load(
        accountId: 'account-7',
        draftId: 'draft-a',
      );
      expect(persistedA?.payload['remark'], 'concurrent update');

      expect(await documents.openDraft('draft-b'), isTrue);
      expect(documents.attachmentStagingIds, ['keep-b']);
      final persistedB = await rebuiltRepository.load(
        accountId: 'account-7',
        draftId: 'draft-b',
      );
      expect(persistedB?.payload['remark'], 'untouched');
      expect(persistedB?.version, 1);

      final drafts = DraftsViewModel(
        repository: rebuiltRepository,
        accountId: 'account-7',
        roleCode: 'operator',
        warehouseId: 1,
        draftIdFactory: () => 'draft-a-copy',
      );
      final copy = await drafts.duplicate('draft-a');
      expect(copy, isNotNull);
      expect(copy?.attachmentStagingIds, isEmpty);
    },
  );
}

const _selection = SelectedAttachmentSource(
  path: '/source/file.pdf',
  originalName: 'file.pdf',
  mimeType: 'application/pdf',
  fileSize: 10,
);

StagedAttachment _staged(String requestId, String draftId) => StagedAttachment(
  pending: PendingAttachment(
    requestId: requestId,
    binding: AttachmentBinding.documentDraft(draftId),
    stagedPath: '/staged/$requestId',
    originalName: '$requestId.pdf',
    mimeType: 'application/pdf',
    fileSize: 10,
  ),
  thumbnailPath: null,
  createdAt: DateTime.utc(2026, 7, 13),
);

DocumentDraft _documentDraft({
  required String id,
  required List<String> attachmentIds,
  required String remark,
}) => DocumentDraft(
  id: id,
  accountId: 'account-7',
  warehouseId: 1,
  docType: 2,
  observedRoleCode: 'operator',
  payload: {
    'remark': remark,
    'lines': const [
      {'product_id': 10, 'product_name': 'Item', 'quantity': 1},
    ],
  },
  attachmentStagingIds: attachmentIds,
  createdAt: DateTime.utc(2026, 7, 13, 9),
  updatedAt: DateTime.utc(2026, 7, 13, 9),
  version: 0,
);

final class _DraftPicker implements AttachmentPicker {
  _DraftPicker({Future<Result<SelectedAttachmentSource?>>? result})
    : result = result ?? Future.value(const Success(_selection));

  final Future<Result<SelectedAttachmentSource?>> result;

  @override
  Future<Result<SelectedAttachmentSource?>> pick(AttachmentPickSource source) =>
      result;

  @override
  Future<Result<List<SelectedAttachmentSource>>> recoverLostData() async =>
      const Success([]);

  @override
  List<SelectedAttachmentSource> takeRecovered() => const [];
}

final class _DraftStaging implements AttachmentStagingStore {
  _DraftStaging({
    Future<Result<StagedAttachment>>? stageResult,
    Future<Result<void>>? removeResult,
    this.recoverResults = const [],
  }) : stageResult =
           stageResult ?? Future.value(Success(_staged('request-1', 'draft'))),
       removeResult = removeResult ?? Future.value(const Success(null));

  final Future<Result<StagedAttachment>> stageResult;
  final Future<Result<void>> removeResult;
  final List<Future<Result<List<StagedAttachment>>>> recoverResults;
  List<StagedAttachment> recovered = [];
  final List<AttachmentBinding> bindings = [];
  final List<String> removed = [];
  final Completer<void> stageStarted = Completer<void>();
  final Completer<void> removeStarted = Completer<void>();
  int recoverCallCount = 0;

  @override
  Future<Result<StagedAttachment>> stage({
    required String userId,
    required AttachmentBinding binding,
    required SelectedAttachmentSource selection,
    required int existingCount,
  }) async {
    bindings.add(binding);
    if (!stageStarted.isCompleted) stageStarted.complete();
    final result = await stageResult;
    return result.when(
      success: (item) =>
          Success(_staged(item.pending.requestId, binding.localDraftId!)),
      failure: FailureResult.new,
    );
  }

  @override
  Future<Result<List<StagedAttachment>>> recoverForUser(String userId) async {
    final index = recoverCallCount++;
    if (index < recoverResults.length) return recoverResults[index];
    return Success(recovered);
  }

  @override
  Future<Result<void>> remove(String userId, String requestId) async {
    removed.add(requestId);
    if (!removeStarted.isCompleted) removeStarted.complete();
    final result = await removeResult;
    if (result case Success<void>()) {
      recovered.removeWhere((item) => item.pending.requestId == requestId);
    }
    return result;
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
  }) async => const Success('/download');
}

final class _ConflictOnceDraftRepository implements DocumentDraftRepository {
  _ConflictOnceDraftRepository(this.delegate);

  final DocumentDraftRepository delegate;
  bool _hasInjectedConflict = false;

  @override
  Future<Result<DocumentDraft>> save(
    DocumentDraft draft, {
    required int expectedVersion,
  }) async {
    if (!_hasInjectedConflict && draft.id == 'draft-a') {
      _hasInjectedConflict = true;
      final current = await delegate.load(
        accountId: draft.accountId,
        draftId: draft.id,
      );
      final payload = Map<String, Object?>.from(current!.payload)
        ..['remark'] = 'concurrent update';
      await delegate.save(
        current.copyWith(payload: payload),
        expectedVersion: current.version,
      );
    }
    return delegate.save(draft, expectedVersion: expectedVersion);
  }

  @override
  Future<DocumentDraft?> load({
    required String accountId,
    required String draftId,
  }) => delegate.load(accountId: accountId, draftId: draftId);

  @override
  Future<List<DocumentDraft>> list(String accountId) =>
      delegate.list(accountId);

  @override
  Future<void> delete({required String accountId, required String draftId}) =>
      delegate.delete(accountId: accountId, draftId: draftId);

  @override
  Future<void> prune() => delegate.prune();
}
