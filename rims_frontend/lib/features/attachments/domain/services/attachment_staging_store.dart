import 'dart:typed_data';

import '../../../../core/result/result.dart';
import '../entities/attachment.dart';
import 'attachment_picker.dart';

final class StagedAttachment {
  const StagedAttachment({
    required this.pending,
    required this.thumbnailPath,
    required this.createdAt,
  });

  final PendingAttachment pending;
  final String? thumbnailPath;
  final DateTime createdAt;
}

abstract interface class AttachmentStagingStore {
  Future<Result<StagedAttachment>> stage({
    required String userId,
    required AttachmentBinding binding,
    required SelectedAttachmentSource selection,
    required int existingCount,
  });

  Future<Result<List<StagedAttachment>>> recoverForUser(String userId);
  Future<Result<void>> remove(String userId, String requestId);
  Future<Result<void>> cleanupStale({required Duration maxAge});
  Future<Result<void>> clearForUser(String userId);
  Future<Result<String>> saveDownload({
    required String userId,
    required String originalName,
    required Uint8List bytes,
  });
}

abstract interface class DraftAttachmentStagingStore {
  Future<Result<List<StagedAttachment>>> duplicateDraftAttachments({
    required String userId,
    required String sourceDraftId,
    required String targetDraftId,
    required List<String> requestIds,
  });

  Future<Result<void>> removeStagedAttachments({
    required String userId,
    required List<String> requestIds,
  });
}
