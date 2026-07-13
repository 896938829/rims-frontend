import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/attachments/domain/entities/attachment.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_staging_store.dart';
import 'package:rims_frontend/features/offline/domain/entities/document_draft.dart';
import 'package:rims_frontend/features/offline/domain/repositories/document_draft_repository.dart';
import 'package:rims_frontend/features/offline/presentation/view_models/drafts_view_model.dart';

void main() {
  final now = DateTime.utc(2026, 7, 13, 12);

  test('loads only the active account and exposes review state', () async {
    final repository = _MemoryDraftRepository([
      _draft('mine', accountId: '7', roleCode: 'old-role'),
      _draft('other', accountId: '8'),
    ]);
    final viewModel = DraftsViewModel(
      repository: repository,
      accountId: '7',
      roleCode: 'operator',
      warehouseId: 11,
    );

    await viewModel.load();

    expect(viewModel.drafts.map((item) => item.draft.id), ['mine']);
    expect(viewModel.drafts.single.requiresReview, isTrue);
  });

  test('opens, duplicates, and renames a draft remark', () async {
    final repository = _MemoryDraftRepository([
      _draft('original', attachmentIds: ['original-file']),
    ]);
    final staging = _FakeDraftAttachmentStagingStore();
    final viewModel = DraftsViewModel(
      repository: repository,
      accountId: '7',
      roleCode: 'operator',
      warehouseId: 11,
      attachmentStagingStore: staging,
      attachmentUserId: '7',
      draftIdFactory: () => 'copy-id',
      now: () => now,
    );
    await viewModel.load();

    expect((await viewModel.open('original'))?.id, 'original');
    final copy = await viewModel.duplicate('original');
    await viewModel.renameRemark('original', 'renamed');

    expect(copy?.id, 'copy-id');
    expect(copy?.version, 1);
    expect(repository.byId('copy-id')?.payload['remark'], 'original remark');
    expect(repository.byId('copy-id')?.attachmentStagingIds, ['copy-file']);
    expect(staging.requests.single.$1, '7');
    expect(staging.requests.single.$2, 'original');
    expect(staging.requests.single.$3, 'copy-id');
    expect(staging.requests.single.$4, ['original-file']);
    expect(repository.byId('original')?.payload['remark'], 'renamed');
  });

  test('discard requires confirmation', () async {
    final repository = _MemoryDraftRepository([_draft('kept')]);
    final viewModel = DraftsViewModel(
      repository: repository,
      accountId: '7',
      roleCode: 'operator',
      warehouseId: 11,
    );
    await viewModel.load();

    expect(await viewModel.discard('kept', confirmed: false), isFalse);
    expect(repository.byId('kept'), isNotNull);
    expect(await viewModel.discard('kept', confirmed: true), isTrue);
    expect(repository.byId('kept'), isNull);
  });

  test(
    'duplicate failure is visible and rolls back copied attachments',
    () async {
      final repository = _MemoryDraftRepository([
        _draft('original', attachmentIds: ['original-file']),
      ], failingDraftId: 'copy-id');
      final staging = _FakeDraftAttachmentStagingStore();
      final viewModel = DraftsViewModel(
        repository: repository,
        accountId: '7',
        roleCode: 'operator',
        warehouseId: 11,
        attachmentStagingStore: staging,
        attachmentUserId: '7',
        draftIdFactory: () => 'copy-id',
      );

      expect(await viewModel.duplicate('original'), isNull);

      expect(viewModel.errorMessage, 'copy draft failed');
      expect(repository.byId('copy-id'), isNull);
      expect(staging.removedRequestIds, ['copy-file']);
    },
  );

  test(
    'account switch replaces visible drafts without cross-account access',
    () async {
      final repository = _MemoryDraftRepository([
        _draft('account-7'),
        _draft('account-8', accountId: '8'),
      ]);
      final viewModel = DraftsViewModel(
        repository: repository,
        accountId: '7',
        roleCode: 'operator',
        warehouseId: 11,
      );
      await viewModel.load();

      await viewModel.updateContext(
        accountId: '8',
        roleCode: 'operator',
        warehouseId: 11,
      );

      expect(viewModel.drafts.map((item) => item.draft.id), ['account-8']);
      expect(await viewModel.open('account-7'), isNull);
    },
  );

  test(
    'account switch duplicates attachments only in the new account',
    () async {
      final repository = _MemoryDraftRepository([
        _draft('account-7', attachmentIds: ['file-7']),
        _draft('account-8', accountId: '8', attachmentIds: ['file-8']),
      ]);
      final staging = _FakeDraftAttachmentStagingStore();
      final viewModel = DraftsViewModel(
        repository: repository,
        accountId: '7',
        roleCode: 'operator',
        warehouseId: 11,
        attachmentStagingStore: staging,
        attachmentUserId: '7',
        draftIdFactory: () => 'copy-8',
      );

      await viewModel.updateContext(
        accountId: '8',
        roleCode: 'operator',
        warehouseId: 11,
        attachmentUserId: '8',
      );
      final copy = await viewModel.duplicate('account-8');

      expect(copy?.accountId, '8');
      expect(staging.requests.map((request) => request.$1), ['8']);
      expect(staging.requests.single.$2, 'account-8');
      expect(staging.requests.single.$4, ['file-8']);
    },
  );

  test('save and attachment rollback failures are both visible', () async {
    final repository = _MemoryDraftRepository([
      _draft('original', attachmentIds: ['original-file']),
    ], failingDraftId: 'copy-id');
    final staging = _FakeDraftAttachmentStagingStore(
      removeResult: const FailureResult(
        LocalStorageFailure(message: 'cleanup failed; retry pending'),
      ),
    );
    final viewModel = DraftsViewModel(
      repository: repository,
      accountId: '7',
      roleCode: 'operator',
      warehouseId: 11,
      attachmentStagingStore: staging,
      attachmentUserId: '7',
      draftIdFactory: () => 'copy-id',
    );

    expect(await viewModel.duplicate('original'), isNull);

    expect(
      viewModel.errorMessage,
      'copy draft failed; attachment cleanup failed: cleanup failed; retry pending',
    );
  });

  test(
    'late duplicate rollback remains scoped to its starting account',
    () async {
      final delayedSave = Completer<Result<DocumentDraft>>();
      final repository = _MemoryDraftRepository([
        _draft('account-7', attachmentIds: ['file-7']),
        _draft('account-8', accountId: '8'),
      ], delayedSave: delayedSave);
      final staging = _FakeDraftAttachmentStagingStore();
      final viewModel = DraftsViewModel(
        repository: repository,
        accountId: '7',
        roleCode: 'operator',
        warehouseId: 11,
        attachmentStagingStore: staging,
        attachmentUserId: '7',
        draftIdFactory: () => 'copy-7',
      );

      final duplicate = viewModel.duplicate('account-7');
      while (staging.requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await viewModel.updateContext(
        accountId: '8',
        roleCode: 'operator',
        warehouseId: 11,
        attachmentUserId: '8',
      );
      delayedSave.complete(
        const FailureResult(LocalStorageFailure(message: 'late save failed')),
      );
      await duplicate;

      expect(staging.removalRequests.single.$1, '7');
      expect(staging.removalRequests.single.$2, ['copy-file']);
      expect(viewModel.drafts.map((item) => item.draft.accountId), ['8']);
    },
  );

  test('late rename result cannot enter the new account list', () async {
    final delayedSave = Completer<Result<DocumentDraft>>();
    final repository = _MemoryDraftRepository([
      _draft('rename-7'),
      _draft('account-8', accountId: '8'),
    ], delayedSave: delayedSave);
    final viewModel = DraftsViewModel(
      repository: repository,
      accountId: '7',
      roleCode: 'operator',
      warehouseId: 11,
    );

    final rename = viewModel.renameRemark('rename-7', 'late rename');
    await repository.saveStarted.future;
    await viewModel.updateContext(
      accountId: '8',
      roleCode: 'operator',
      warehouseId: 11,
    );
    delayedSave.complete(
      Success(
        _draft('rename-7').copyWith(
          payload: const {'lines': [], 'remark': 'late rename'},
          version: 2,
        ),
      ),
    );

    expect(await rename, isFalse);
    expect(viewModel.drafts.map((item) => item.draft.id), ['account-8']);
  });

  test('late discard cannot remove the same id from the new account', () async {
    final repository = _ScopedDelayedDeleteRepository();
    final viewModel = DraftsViewModel(
      repository: repository,
      accountId: '7',
      roleCode: 'operator',
      warehouseId: 11,
    );
    await viewModel.load();

    final discard = viewModel.discard('shared-id', confirmed: true);
    await repository.deleteStarted.future;
    await viewModel.updateContext(
      accountId: '8',
      roleCode: 'operator',
      warehouseId: 11,
    );
    repository.releaseDelete.complete();

    expect(await discard, isFalse);
    expect(viewModel.drafts.map((item) => item.draft.id), ['shared-id']);
    expect(viewModel.drafts.single.draft.accountId, '8');
  });

  test(
    'late duplicate success compensates old account draft and files',
    () async {
      final delayedSave = Completer<Result<DocumentDraft>>();
      final repository = _MemoryDraftRepository([
        _draft('source-7', attachmentIds: ['file-7']),
        _draft('account-8', accountId: '8'),
      ], delayedSave: delayedSave);
      final staging = _FakeDraftAttachmentStagingStore();
      final viewModel = DraftsViewModel(
        repository: repository,
        accountId: '7',
        roleCode: 'operator',
        warehouseId: 11,
        attachmentStagingStore: staging,
        attachmentUserId: '7',
        draftIdFactory: () => 'copy-7',
      );

      final duplicate = viewModel.duplicate('source-7');
      await repository.saveStarted.future;
      await viewModel.updateContext(
        accountId: '8',
        roleCode: 'operator',
        warehouseId: 11,
        attachmentUserId: '8',
      );
      delayedSave.complete(
        Success(_draft('copy-7', attachmentIds: ['copy-file'])),
      );

      expect(await duplicate, isNull);
      expect(repository.deleted, [('7', 'copy-7')]);
      expect(staging.removalRequests.single.$1, '7');
      expect(staging.removalRequests.single.$2, ['copy-file']);
      expect(viewModel.drafts.map((item) => item.draft.id), ['account-8']);
    },
  );

  test(
    'discard reports pending attachment cleanup after draft deletion',
    () async {
      final repository = _MemoryDraftRepository([
        _draft('discard-me', attachmentIds: ['staged-file']),
      ]);
      final staging = _FakeDraftAttachmentStagingStore(
        removeResult: const FailureResult(
          LocalStorageFailure(message: 'cleanup pending'),
        ),
      );
      final viewModel = DraftsViewModel(
        repository: repository,
        accountId: '7',
        roleCode: 'operator',
        warehouseId: 11,
        attachmentStagingStore: staging,
        attachmentUserId: '7',
      );
      await viewModel.load();

      expect(await viewModel.discard('discard-me', confirmed: true), isTrue);

      expect(repository.byId('discard-me'), isNull);
      expect(staging.removalRequests.single.$1, '7');
      expect(staging.removalRequests.single.$2, ['staged-file']);
      expect(viewModel.errorMessage, '草稿已删除；附件清理待重试: cleanup pending');
    },
  );

  test('a rebuilt view model recovers persisted drafts', () async {
    final repository = _MemoryDraftRepository([_draft('persisted')]);
    final first = DraftsViewModel(
      repository: repository,
      accountId: '7',
      roleCode: 'operator',
      warehouseId: 11,
    );
    await first.load();
    first.dispose();

    final rebuilt = DraftsViewModel(
      repository: repository,
      accountId: '7',
      roleCode: 'operator',
      warehouseId: 11,
    );
    await rebuilt.load();

    expect(rebuilt.drafts.single.draft.id, 'persisted');
  });

  test(
    'late account results cannot replace the active account drafts',
    () async {
      final repository = _DelayedListDraftRepository();
      final viewModel = DraftsViewModel(
        repository: repository,
        accountId: '7',
        roleCode: 'operator',
        warehouseId: 11,
      );

      final oldLoad = viewModel.load();
      final switchAccount = viewModel.updateContext(
        accountId: '8',
        roleCode: 'operator',
        warehouseId: 11,
      );
      repository.complete('8', [_draft('account-8', accountId: '8')]);
      await switchAccount;
      repository.complete('7', [_draft('account-7')]);
      await oldLoad;

      expect(viewModel.drafts.map((item) => item.draft.id), ['account-8']);
    },
  );

  test('late open result is rejected after account switch', () async {
    final repository = _DelayedOpenDraftRepository();
    final viewModel = DraftsViewModel(
      repository: repository,
      accountId: '7',
      roleCode: 'operator',
      warehouseId: 11,
    );

    final opened = viewModel.open('draft-7');
    await repository.openStarted.future;
    await viewModel.updateContext(
      accountId: '8',
      roleCode: 'operator',
      warehouseId: 11,
    );
    repository.openResult.complete(_draft('draft-7'));

    expect(await opened, isNull);
    expect(viewModel.drafts, isEmpty);
  });
}

DocumentDraft _draft(
  String id, {
  String accountId = '7',
  String roleCode = 'operator',
  List<String> attachmentIds = const [],
}) {
  final timestamp = DateTime.utc(2026, 7, 1);
  return DocumentDraft(
    id: id,
    accountId: accountId,
    warehouseId: 11,
    docType: 2,
    observedRoleCode: roleCode,
    attachmentStagingIds: attachmentIds,
    payload: const {
      'lines': [
        {'product_id': 10, 'product_name': 'Product', 'quantity': 2},
      ],
      'remark': 'original remark',
    },
    createdAt: timestamp,
    updatedAt: timestamp,
    version: 1,
  );
}

final class _MemoryDraftRepository implements DocumentDraftRepository {
  _MemoryDraftRepository(
    List<DocumentDraft> drafts, {
    this.failingDraftId,
    this.delayedSave,
  }) : _drafts = {for (final draft in drafts) draft.id: draft};

  final Map<String, DocumentDraft> _drafts;
  final String? failingDraftId;
  final Completer<Result<DocumentDraft>>? delayedSave;
  final Completer<void> saveStarted = Completer<void>();
  final List<(String, String)> deleted = [];

  DocumentDraft? byId(String id) => _drafts[id];

  @override
  Future<Result<DocumentDraft>> save(
    DocumentDraft draft, {
    required int expectedVersion,
  }) async {
    if (delayedSave case final completer?) {
      if (!saveStarted.isCompleted) saveStarted.complete();
      final result = await completer.future;
      if (result case Success(:final data)) _drafts[data.id] = data;
      return result;
    }
    if (draft.id == failingDraftId) {
      return const FailureResult(
        LocalStorageFailure(message: 'copy draft failed'),
      );
    }
    final saved = draft.copyWith(version: expectedVersion + 1);
    _drafts[draft.id] = saved;
    return Success(saved);
  }

  @override
  Future<DocumentDraft?> load({
    required String accountId,
    required String draftId,
  }) async {
    final draft = _drafts[draftId];
    return draft?.accountId == accountId ? draft : null;
  }

  @override
  Future<List<DocumentDraft>> list(String accountId) async => _drafts.values
      .where((draft) => draft.accountId == accountId)
      .toList(growable: false);

  @override
  Future<void> delete({
    required String accountId,
    required String draftId,
  }) async {
    deleted.add((accountId, draftId));
    if (_drafts[draftId]?.accountId == accountId) _drafts.remove(draftId);
  }

  @override
  Future<void> prune() async {}
}

final class _FakeDraftAttachmentStagingStore
    implements DraftAttachmentStagingStore {
  _FakeDraftAttachmentStagingStore({this.removeResult = const Success(null)});

  final Result<void> removeResult;
  final List<(String, String, String, List<String>)> requests = [];
  final List<String> removedRequestIds = [];
  final List<(String, List<String>)> removalRequests = [];

  @override
  Future<Result<List<StagedAttachment>>> duplicateDraftAttachments({
    required String userId,
    required String sourceDraftId,
    required String targetDraftId,
    required List<String> requestIds,
  }) async {
    requests.add((userId, sourceDraftId, targetDraftId, requestIds));
    return Success([
      StagedAttachment(
        pending: PendingAttachment(
          requestId: 'copy-file',
          binding: AttachmentBinding.documentDraft(targetDraftId),
          stagedPath: '/copy/copy-file.pdf',
          originalName: 'copy.pdf',
          mimeType: 'application/pdf',
          fileSize: 10,
        ),
        thumbnailPath: null,
        createdAt: DateTime.utc(2026, 7, 13),
      ),
    ]);
  }

  @override
  Future<Result<void>> removeStagedAttachments({
    required String userId,
    required List<String> requestIds,
  }) async {
    removedRequestIds.addAll(requestIds);
    removalRequests.add((userId, requestIds));
    return removeResult;
  }
}

final class _DelayedListDraftRepository implements DocumentDraftRepository {
  final Map<String, Completer<List<DocumentDraft>>> _lists = {};

  void complete(String accountId, List<DocumentDraft> drafts) {
    (_lists[accountId] ??= Completer()).complete(drafts);
  }

  @override
  Future<List<DocumentDraft>> list(String accountId) =>
      (_lists[accountId] ??= Completer()).future;

  @override
  Future<void> delete({
    required String accountId,
    required String draftId,
  }) async {}

  @override
  Future<DocumentDraft?> load({
    required String accountId,
    required String draftId,
  }) async => null;

  @override
  Future<void> prune() async {}

  @override
  Future<Result<DocumentDraft>> save(
    DocumentDraft draft, {
    required int expectedVersion,
  }) async => Success(draft);
}

final class _ScopedDelayedDeleteRepository implements DocumentDraftRepository {
  final Completer<void> deleteStarted = Completer<void>();
  final Completer<void> releaseDelete = Completer<void>();

  @override
  Future<List<DocumentDraft>> list(String accountId) async => [
    _draft('shared-id', accountId: accountId),
  ];

  @override
  Future<DocumentDraft?> load({
    required String accountId,
    required String draftId,
  }) async => _draft(draftId, accountId: accountId);

  @override
  Future<void> delete({
    required String accountId,
    required String draftId,
  }) async {
    deleteStarted.complete();
    await releaseDelete.future;
  }

  @override
  Future<Result<DocumentDraft>> save(
    DocumentDraft draft, {
    required int expectedVersion,
  }) async => Success(draft);

  @override
  Future<void> prune() async {}
}

final class _DelayedOpenDraftRepository implements DocumentDraftRepository {
  final Completer<void> openStarted = Completer<void>();
  final Completer<DocumentDraft?> openResult = Completer<DocumentDraft?>();

  @override
  Future<DocumentDraft?> load({
    required String accountId,
    required String draftId,
  }) async {
    openStarted.complete();
    return openResult.future;
  }

  @override
  Future<List<DocumentDraft>> list(String accountId) async => const [];

  @override
  Future<void> delete({
    required String accountId,
    required String draftId,
  }) async {}

  @override
  Future<Result<DocumentDraft>> save(
    DocumentDraft draft, {
    required int expectedVersion,
  }) async => Success(draft);

  @override
  Future<void> prune() async {}
}
