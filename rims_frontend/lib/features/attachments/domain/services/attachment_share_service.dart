import '../../../../core/result/result.dart';

abstract interface class AttachmentShareService {
  Future<Result<void>> share({
    required String path,
    required String originalName,
    required String mimeType,
  });
}
