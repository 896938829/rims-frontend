import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/result.dart';
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
    final viewModel = DraftsViewModel(
      repository: repository,
      accountId: '7',
      roleCode: 'operator',
      warehouseId: 11,
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
    expect(repository.byId('copy-id')?.attachmentStagingIds, isEmpty);
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
  _MemoryDraftRepository(List<DocumentDraft> drafts)
    : _drafts = {for (final draft in drafts) draft.id: draft};

  final Map<String, DocumentDraft> _drafts;

  DocumentDraft? byId(String id) => _drafts[id];

  @override
  Future<Result<DocumentDraft>> save(
    DocumentDraft draft, {
    required int expectedVersion,
  }) async {
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
    if (_drafts[draftId]?.accountId == accountId) _drafts.remove(draftId);
  }

  @override
  Future<void> prune() async {}
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
