import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/attachments/domain/entities/attachment.dart';
import 'package:rims_frontend/features/attachments/domain/repositories/attachments_repository.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_picker.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_share_service.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_staging_store.dart';
import 'package:rims_frontend/features/attachments/presentation/view_models/attachments_view_model.dart';
import 'package:rims_frontend/features/attachments/presentation/widgets/attachment_panel.dart';

void main() {
  testWidgets(
    'panel exposes source tools, stable rows, and attachment actions',
    (tester) async {
      final repository = _PanelRepository();
      final viewModel = AttachmentsViewModel(
        repository: repository,
        picker: _NoopPicker(),
        stagingStore: _NoopStaging(),
        shareService: _NoopShare(),
        binding: AttachmentBinding.document(42),
        userId: '3',
      );
      addTearDown(viewModel.dispose);
      await viewModel.load();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AttachmentPanel(viewModel: viewModel, autoLoad: false),
            ),
          ),
        ),
      );

      expect(find.byTooltip('拍照'), findsOneWidget);
      expect(find.byTooltip('从相册选择'), findsOneWidget);
      expect(find.byTooltip('选择文件'), findsOneWidget);
      expect(find.byKey(const Key('attachment-7')), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('attachment-7'))).height, 76);

      await tester.tap(find.byTooltip('附件操作'));
      await tester.pumpAndSettle();
      expect(find.text('下载并分享'), findsOneWidget);
      expect(find.text('替换'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    },
  );
}

Attachment _attachment() => Attachment(
  id: 7,
  binding: AttachmentBinding.document(42),
  downloadUri: Uri.parse('http://localhost:8080/api/v1/files/7/download'),
  originalName: 'receipt.pdf',
  fileSize: 128,
  mimeType: 'application/pdf',
  fileHash: 'hash',
  isPublic: false,
  createdBy: 3,
  uploadedAt: DateTime.utc(2026, 7, 13),
  position: 0,
);

final class _PanelRepository implements AttachmentsRepository {
  @override
  Future<Result<PageData<Attachment>>> list({
    required AttachmentBinding binding,
    int page = 1,
  }) async => Success(
    PageData(items: [_attachment()], total: 1, page: 1, pageSize: 20),
  );

  @override
  Future<Result<Attachment>> upload(
    PendingAttachment pending, {
    required TransferProgress onProgress,
    required TransferCancellation cancellation,
  }) async => Success(_attachment());

  @override
  Future<Result<Attachment>> replace(
    Attachment existing,
    PendingAttachment pending, {
    required TransferProgress onProgress,
    required TransferCancellation cancellation,
  }) async => Success(existing);

  @override
  Future<Result<void>> reorder(
    AttachmentBinding binding,
    List<int> fileIds,
  ) async => const Success(null);

  @override
  Future<Result<String>> download(Attachment attachment) async =>
      const Success('/support/receipt.pdf');

  @override
  Future<Result<void>> delete(int id) async => const Success(null);
}

final class _NoopPicker implements AttachmentPicker {
  @override
  Future<Result<SelectedAttachmentSource?>> pick(
    AttachmentPickSource source,
  ) async => const Success(null);
  @override
  Future<Result<List<SelectedAttachmentSource>>> recoverLostData() async =>
      const Success([]);
  @override
  List<SelectedAttachmentSource> takeRecovered() => const [];
}

final class _NoopStaging implements AttachmentStagingStore {
  @override
  Future<Result<StagedAttachment>> stage({
    required String userId,
    required AttachmentBinding binding,
    required SelectedAttachmentSource selection,
    required int existingCount,
  }) => throw UnimplementedError();
  @override
  Future<Result<List<StagedAttachment>>> recoverForUser(String userId) async =>
      const Success([]);
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
  }) async => const Success('');
}

final class _NoopShare implements AttachmentShareService {
  @override
  Future<Result<void>> share({
    required String path,
    required String originalName,
    required String mimeType,
  }) async => const Success(null);
}
