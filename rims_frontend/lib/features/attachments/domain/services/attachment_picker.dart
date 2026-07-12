import '../../../../core/result/result.dart';

enum AttachmentPickSource { camera, gallery, file }

final class SelectedAttachmentSource {
  const SelectedAttachmentSource({
    required this.path,
    required this.originalName,
    required this.mimeType,
    required this.fileSize,
  });

  final String path;
  final String originalName;
  final String mimeType;
  final int fileSize;
}

abstract interface class AttachmentPicker {
  Future<Result<SelectedAttachmentSource?>> pick(AttachmentPickSource source);
  Future<Result<List<SelectedAttachmentSource>>> recoverLostData();
  List<SelectedAttachmentSource> takeRecovered();
}
