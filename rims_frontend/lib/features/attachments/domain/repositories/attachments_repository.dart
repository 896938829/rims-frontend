import '../../../../core/pagination/page_data.dart';
import '../../../../core/result/result.dart';
import '../entities/attachment.dart';

typedef TransferProgress = void Function(int sent, int total);

abstract interface class AttachmentsRepository {
  Future<Result<PageData<Attachment>>> list({
    required AttachmentBinding binding,
    int page = 1,
  });

  Future<Result<Attachment>> upload(
    PendingAttachment pending, {
    required TransferProgress onProgress,
    required TransferCancellation cancellation,
  });

  Future<Result<Attachment>> replace(
    Attachment existing,
    PendingAttachment pending, {
    required TransferProgress onProgress,
    required TransferCancellation cancellation,
  });

  Future<Result<void>> reorder(AttachmentBinding binding, List<int> fileIds);

  Future<Result<String>> download(Attachment attachment);

  Future<Result<void>> delete(int id);
}
