import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/attachments/domain/entities/attachment.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_picker.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_staging_store.dart';
import 'package:rims_frontend/features/offline/presentation/view_models/draft_attachments_view_model.dart';

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
    this.recoverResults = const [],
  }) : stageResult =
           stageResult ?? Future.value(Success(_staged('request-1', 'draft')));

  final Future<Result<StagedAttachment>> stageResult;
  final List<Future<Result<List<StagedAttachment>>>> recoverResults;
  List<StagedAttachment> recovered = [];
  final List<AttachmentBinding> bindings = [];
  final List<String> removed = [];
  final Completer<void> stageStarted = Completer<void>();
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
    return const Success(null);
  }

  @override
  Future<Result<void>> cleanupStale({required Duration maxAge}) async =>
      const Success(null);

  @override
  Future<Result<void>> clearForUser(String userId) async => const Success(null);

  @override
  Future<Result<String>> saveDownload({
    required String userId,
    required String originalName,
    required Uint8List bytes,
  }) async => const Success('/download');
}
