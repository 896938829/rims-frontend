import 'dart:io';

import 'package:share_plus/share_plus.dart';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';

typedef ShareLocalFile =
    Future<void> Function(String path, String originalName, String mimeType);

abstract interface class AttachmentShareService {
  Future<Result<void>> share({
    required String path,
    required String originalName,
    required String mimeType,
  });
}

final class PlatformAttachmentShareService implements AttachmentShareService {
  PlatformAttachmentShareService({
    Future<bool> Function(String path)? fileExists,
    ShareLocalFile? shareFile,
  }) : _fileExists = fileExists ?? ((path) => File(path).exists()),
       _shareFile = shareFile ?? _platformShare;

  final Future<bool> Function(String path) _fileExists;
  final ShareLocalFile _shareFile;

  @override
  Future<Result<void>> share({
    required String path,
    required String originalName,
    required String mimeType,
  }) async {
    try {
      if (!await _fileExists(path)) {
        return const FailureResult(
          LocalStorageFailure(message: 'Downloaded attachment is missing.'),
        );
      }
      await _shareFile(path, originalName, mimeType);
      return const Success(null);
    } catch (error) {
      return FailureResult(
        AttachmentFailure(message: 'Unable to share attachment.', cause: error),
      );
    }
  }
}

Future<void> _platformShare(
  String path,
  String originalName,
  String mimeType,
) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(path, name: originalName, mimeType: mimeType)],
      fileNameOverrides: [originalName],
    ),
  );
}
