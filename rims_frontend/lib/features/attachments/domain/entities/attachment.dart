final class AttachmentBinding {
  const AttachmentBinding._(
    this.businessType,
    this.businessId, {
    this.localDraftId,
  }) : assert(businessId > 0);

  factory AttachmentBinding.productImage(int productId) {
    if (productId <= 0) {
      throw ArgumentError.value(productId, 'productId', 'Must be positive');
    }
    return AttachmentBinding._('product_image', productId);
  }

  factory AttachmentBinding.document(int documentId) {
    if (documentId <= 0) {
      throw ArgumentError.value(documentId, 'documentId', 'Must be positive');
    }
    return AttachmentBinding._('doc_attachment', documentId);
  }

  factory AttachmentBinding.documentDraft(String draftId) {
    final normalized = draftId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(draftId, 'draftId', 'Must not be empty');
    }
    return AttachmentBinding._('document_draft', 1, localDraftId: normalized);
  }

  factory AttachmentBinding.fromBackend({
    required String businessType,
    required int businessId,
  }) {
    if (businessId <= 0) {
      throw const FormatException('Attachment businessId must be positive.');
    }
    if (businessType != 'product_image' && businessType != 'doc_attachment') {
      throw FormatException(
        'Unsupported attachment businessType: $businessType',
      );
    }
    return AttachmentBinding._(businessType, businessId);
  }

  factory AttachmentBinding.fromStorage({
    required String businessType,
    required int businessId,
    String? localDraftId,
  }) {
    if (businessType == 'document_draft') {
      return AttachmentBinding.documentDraft(localDraftId ?? '');
    }
    return AttachmentBinding.fromBackend(
      businessType: businessType,
      businessId: businessId,
    );
  }

  final String businessType;
  final int businessId;
  final String? localDraftId;

  @override
  bool operator ==(Object other) =>
      other is AttachmentBinding &&
      other.businessType == businessType &&
      other.businessId == businessId &&
      other.localDraftId == localDraftId;

  @override
  int get hashCode => Object.hash(businessType, businessId, localDraftId);
}

final class Attachment {
  const Attachment({
    required this.id,
    required this.binding,
    required this.downloadUri,
    required this.originalName,
    required this.fileSize,
    required this.mimeType,
    required this.fileHash,
    required this.isPublic,
    required this.createdBy,
    required this.uploadedAt,
    required this.position,
  });

  final int id;
  final AttachmentBinding binding;
  final Uri downloadUri;
  final String originalName;
  final int fileSize;
  final String mimeType;
  final String fileHash;
  final bool isPublic;
  final int createdBy;
  final DateTime uploadedAt;
  final int position;
}

final class PendingAttachment {
  PendingAttachment({
    required this.requestId,
    required this.binding,
    required this.stagedPath,
    required this.originalName,
    required this.mimeType,
    required this.fileSize,
  }) {
    if (requestId.trim().isEmpty) {
      throw ArgumentError.value(requestId, 'requestId', 'Must not be empty');
    }
    if (stagedPath.trim().isEmpty || originalName.trim().isEmpty) {
      throw ArgumentError('Staged path and original name must not be empty');
    }
    if (fileSize < 0) {
      throw ArgumentError.value(fileSize, 'fileSize', 'Must not be negative');
    }
  }

  final String requestId;
  final AttachmentBinding binding;
  final String stagedPath;
  final String originalName;
  final String mimeType;
  final int fileSize;
}

typedef CancellationListener = void Function();

final class TransferCancellation {
  bool _isCancelled = false;
  final Set<CancellationListener> _listeners = {};

  bool get isCancelled => _isCancelled;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    for (final listener in _listeners.toList(growable: false)) {
      listener();
    }
    _listeners.clear();
  }

  void addListener(CancellationListener listener) {
    if (_isCancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void removeListener(CancellationListener listener) {
    _listeners.remove(listener);
  }
}
