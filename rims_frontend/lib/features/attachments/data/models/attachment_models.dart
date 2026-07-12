import '../../domain/entities/attachment.dart';

final class AttachmentModel {
  const AttachmentModel({
    required this.id,
    required this.businessType,
    required this.businessId,
    required this.fileUrl,
    required this.originalName,
    required this.fileSize,
    required this.mimeType,
    required this.fileHash,
    required this.isPublic,
    required this.createdBy,
    required this.uploadedAt,
    required this.position,
  });

  factory AttachmentModel.fromJson(Map<String, Object?> json) {
    final id = _positiveInt(json, 'id');
    final businessId = _positiveInt(json, 'businessId');
    final fileSize = _integer(json, 'fileSize');
    final createdBy = _positiveInt(json, 'createdBy');
    final position = _integer(json, 'position');
    if (fileSize < 0 || position < 0) {
      throw const FormatException(
        'Attachment fileSize and position must not be negative.',
      );
    }
    final uploadedAtText = _nonEmptyString(json, 'uploadedAt');
    final uploadedAt = DateTime.tryParse(uploadedAtText);
    if (uploadedAt == null) {
      throw const FormatException('Attachment uploadedAt must be ISO-8601.');
    }
    final isPublic = json['isPublic'];
    if (isPublic is! bool) {
      throw const FormatException('Attachment isPublic must be a boolean.');
    }

    return AttachmentModel(
      id: id,
      businessType: _nonEmptyString(json, 'businessType'),
      businessId: businessId,
      fileUrl: _nonEmptyString(json, 'fileUrl'),
      originalName: _nonEmptyString(json, 'originalName'),
      fileSize: fileSize,
      mimeType: _nonEmptyString(json, 'mimeType'),
      fileHash: _string(json, 'fileHash'),
      isPublic: isPublic,
      createdBy: createdBy,
      uploadedAt: uploadedAt.toUtc(),
      position: position,
    );
  }

  final int id;
  final String businessType;
  final int businessId;
  final String fileUrl;
  final String originalName;
  final int fileSize;
  final String mimeType;
  final String fileHash;
  final bool isPublic;
  final int createdBy;
  final DateTime uploadedAt;
  final int position;

  Attachment toEntity(Uri apiBaseUri) {
    final rawUri = Uri.tryParse(fileUrl);
    if (rawUri == null ||
        rawUri.hasScheme ||
        rawUri.hasAuthority ||
        !fileUrl.startsWith('/') ||
        rawUri.hasQuery ||
        rawUri.hasFragment) {
      throw const FormatException(
        'Attachment fileUrl must be a same-origin absolute path.',
      );
    }
    final origin = apiBaseUri.replace(path: '/', query: null, fragment: null);
    final resolved = origin.resolveUri(rawUri);
    if (resolved.scheme != origin.scheme ||
        resolved.host != origin.host ||
        resolved.port != origin.port) {
      throw const FormatException('Attachment fileUrl changed API origin.');
    }

    return Attachment(
      id: id,
      binding: AttachmentBinding.fromBackend(
        businessType: businessType,
        businessId: businessId,
      ),
      downloadUri: resolved,
      originalName: originalName,
      fileSize: fileSize,
      mimeType: mimeType,
      fileHash: fileHash,
      isPublic: isPublic,
      createdBy: createdBy,
      uploadedAt: uploadedAt,
      position: position,
    );
  }
}

int _positiveInt(Map<String, Object?> json, String key) {
  final value = _integer(json, key);
  if (value <= 0) {
    throw FormatException('Attachment $key must be positive.');
  }
  return value;
}

int _integer(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.truncate()) {
    return value.toInt();
  }
  throw FormatException('Attachment $key must be an integer.');
}

String _nonEmptyString(Map<String, Object?> json, String key) {
  final value = _string(json, key);
  if (value.trim().isEmpty) {
    throw FormatException('Attachment $key must not be empty.');
  }
  return value;
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('Attachment $key must be a string.');
  }
  return value;
}
