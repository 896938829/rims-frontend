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
}

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
  @override
  Future<Result<SelectedAttachmentSource?>> pick(
    AttachmentPickSource source,
  ) async => const Success(
    SelectedAttachmentSource(
      path: '/source/file.pdf',
      originalName: 'file.pdf',
      mimeType: 'application/pdf',
      fileSize: 10,
    ),
  );

  @override
  Future<Result<List<SelectedAttachmentSource>>> recoverLostData() async =>
      const Success([]);

  @override
  List<SelectedAttachmentSource> takeRecovered() => const [];
}

final class _DraftStaging implements AttachmentStagingStore {
  List<StagedAttachment> recovered = [];
  final List<AttachmentBinding> bindings = [];

  @override
  Future<Result<StagedAttachment>> stage({
    required String userId,
    required AttachmentBinding binding,
    required SelectedAttachmentSource selection,
    required int existingCount,
  }) async {
    bindings.add(binding);
    return Success(_staged('request-1', binding.localDraftId!));
  }

  @override
  Future<Result<List<StagedAttachment>>> recoverForUser(String userId) async =>
      Success(recovered);

  @override
  Future<Result<void>> remove(String userId, String requestId) async =>
      const Success(null);

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
