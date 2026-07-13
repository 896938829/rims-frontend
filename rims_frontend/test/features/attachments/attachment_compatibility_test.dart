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
  for (final configuration in const [
    (name: 'phone light', size: Size(320, 640), dark: false),
    (name: 'phone dark', size: Size(360, 800), dark: true),
    (name: 'tablet portrait', size: Size(800, 1280), dark: false),
    (name: 'tablet landscape', size: Size(1280, 800), dark: true),
  ]) {
    testWidgets('attachment tools support ${configuration.name}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(configuration.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final viewModel = _viewModel();
      addTearDown(viewModel.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: configuration.dark ? Brightness.dark : Brightness.light,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              viewInsets: const EdgeInsets.only(bottom: 280),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: AttachmentPanel(viewModel: viewModel, autoLoad: false),
            ),
          ),
        ),
      );

      expect(find.byTooltip('拍照'), findsOneWidget);
      expect(find.byTooltip('从相册选择'), findsOneWidget);
      expect(find.byTooltip('选择文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

AttachmentsViewModel _viewModel() => AttachmentsViewModel(
  repository: _Repository(),
  picker: _Picker(),
  stagingStore: _Staging(),
  shareService: _Share(),
  binding: AttachmentBinding.document(1),
  userId: 'compatibility-user',
);

final class _Repository implements AttachmentsRepository {
  @override
  Future<Result<PageData<Attachment>>> list({
    required AttachmentBinding binding,
    int page = 1,
  }) async =>
      Success(PageData(items: const [], total: 0, page: 1, pageSize: 20));

  @override
  Future<Result<Attachment>> upload(
    PendingAttachment pending, {
    required TransferProgress onProgress,
    required TransferCancellation cancellation,
  }) => throw UnimplementedError();

  @override
  Future<Result<Attachment>> replace(
    Attachment existing,
    PendingAttachment pending, {
    required TransferProgress onProgress,
    required TransferCancellation cancellation,
  }) => throw UnimplementedError();

  @override
  Future<Result<void>> reorder(
    AttachmentBinding binding,
    List<int> fileIds,
  ) async => const Success(null);

  @override
  Future<Result<String>> download(Attachment attachment) async =>
      const Success('');

  @override
  Future<Result<void>> delete(int id) async => const Success(null);
}

final class _Picker implements AttachmentPicker {
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

final class _Staging implements AttachmentStagingStore {
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
  }) async => const Success('');
}

final class _Share implements AttachmentShareService {
  @override
  Future<Result<void>> share({
    required String path,
    required String originalName,
    required String mimeType,
  }) async => const Success(null);
}
