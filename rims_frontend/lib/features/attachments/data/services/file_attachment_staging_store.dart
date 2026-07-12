import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/entities/attachment.dart';
import '../../domain/services/attachment_picker.dart';
import '../../domain/services/attachment_staging_store.dart';
import 'android_attachment_picker.dart';

const int _manifestVersion = 1;
const int _maximumFileSize = 10 * 1024 * 1024;
const int _maximumAttachmentCount = 9;
const int _thumbnailLongestSide = 512;

typedef DirectoryProvider = Future<Directory> Function();
typedef FileCopier = Future<void> Function(String source, String destination);
typedef ThumbnailBuilder =
    Future<String?> Function(String source, String destination);

final class FileAttachmentStagingStore implements AttachmentStagingStore {
  FileAttachmentStagingStore({
    required DirectoryProvider rootDirectory,
    required String Function() idFactory,
    DateTime Function()? clock,
    FileCopier? copyFile,
    ThumbnailBuilder? thumbnailBuilder,
  }) : this._(
         rootDirectory,
         idFactory,
         clock ?? DateTime.now,
         copyFile ?? _defaultCopy,
         thumbnailBuilder ?? buildBoundedThumbnail,
       );

  FileAttachmentStagingStore._(
    this._rootDirectory,
    this._idFactory,
    this._clock,
    this._copyFile,
    this._thumbnailBuilder,
  );

  final DirectoryProvider _rootDirectory;
  final String Function() _idFactory;
  final DateTime Function() _clock;
  final FileCopier _copyFile;
  final ThumbnailBuilder _thumbnailBuilder;

  @override
  Future<Result<StagedAttachment>> stage({
    required String userId,
    required AttachmentBinding binding,
    required SelectedAttachmentSource selection,
    required int existingCount,
  }) async {
    final validation = _validate(selection, existingCount);
    if (validation != null) return FailureResult(validation);

    final requestId = _idFactory();
    final extension = _extension(selection.originalName);
    final userDirectory = await _userDirectory(userId);
    final stagedDirectory = Directory(
      '${userDirectory.path}${Platform.pathSeparator}staged',
    );
    final thumbnailsDirectory = Directory(
      '${userDirectory.path}${Platform.pathSeparator}thumbnails',
    );
    final stagedPath =
        '${stagedDirectory.path}${Platform.pathSeparator}$requestId.$extension';
    final thumbnailPath =
        '${thumbnailsDirectory.path}${Platform.pathSeparator}$requestId.png';

    try {
      await stagedDirectory.create(recursive: true);
      if (await File(stagedPath).exists()) {
        return const FailureResult(
          LocalStorageFailure(
            message: 'Attachment staging identifier collision.',
          ),
        );
      }
      await _copyFile(selection.path, stagedPath);
      final actualSize = await File(stagedPath).length();
      if (actualSize > _maximumFileSize) {
        throw const FileSystemException('Attachment exceeds size limit.');
      }
      String? createdThumbnail;
      if (selection.mimeType.startsWith('image/')) {
        await thumbnailsDirectory.create(recursive: true);
        createdThumbnail = await _thumbnailBuilder(stagedPath, thumbnailPath);
      }
      final staged = StagedAttachment(
        pending: PendingAttachment(
          requestId: requestId,
          binding: binding,
          stagedPath: stagedPath,
          originalName: selection.originalName,
          mimeType: selection.mimeType,
          fileSize: actualSize,
        ),
        thumbnailPath: createdThumbnail,
        createdAt: _clock().toUtc(),
      );
      final current = await _readManifest(userDirectory);
      await _writeManifest(userDirectory, [...current, staged]);
      return Success(staged);
    } catch (error) {
      await _deleteIfExists(File(stagedPath));
      await _deleteIfExists(File(thumbnailPath));
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to stage attachment in application storage.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<List<StagedAttachment>>> recoverForUser(String userId) async {
    try {
      final directory = await _userDirectory(userId, create: false);
      if (!await directory.exists()) return const Success([]);
      final items = await _readManifest(directory);
      final existing = <StagedAttachment>[];
      for (final item in items) {
        if (await File(item.pending.stagedPath).exists()) existing.add(item);
      }
      if (existing.length != items.length) {
        await _writeManifest(directory, existing);
      }
      return Success(List.unmodifiable(existing));
    } catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to recover staged attachments.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void>> remove(String userId, String requestId) async {
    try {
      final directory = await _userDirectory(userId, create: false);
      if (!await directory.exists()) return const Success(null);
      final items = await _readManifest(directory);
      final retained = <StagedAttachment>[];
      for (final item in items) {
        if (item.pending.requestId == requestId) {
          await _deleteIfExists(File(item.pending.stagedPath));
          final thumbnail = item.thumbnailPath;
          if (thumbnail != null) await _deleteIfExists(File(thumbnail));
        } else {
          retained.add(item);
        }
      }
      await _writeManifest(directory, retained);
      return const Success(null);
    } catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to remove attachment.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void>> cleanupStale({required Duration maxAge}) async {
    try {
      final root = await _attachmentRoot(create: false);
      if (!await root.exists()) return const Success(null);
      final cutoff = _clock().toUtc().subtract(maxAge);
      await for (final entity in root.list()) {
        if (entity is! Directory) continue;
        final items = await _readManifest(entity);
        final retained = <StagedAttachment>[];
        for (final item in items) {
          if (item.createdAt.isBefore(cutoff)) {
            await _deleteIfExists(File(item.pending.stagedPath));
            final thumbnail = item.thumbnailPath;
            if (thumbnail != null) await _deleteIfExists(File(thumbnail));
          } else {
            retained.add(item);
          }
        }
        await _writeManifest(entity, retained);
        await _deleteFilesOlderThan(
          Directory('${entity.path}${Platform.pathSeparator}downloads'),
          cutoff,
        );
      }
      return const Success(null);
    } catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to clean stale attachments.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void>> clearForUser(String userId) async {
    try {
      final directory = await _userDirectory(userId, create: false);
      if (await directory.exists()) await directory.delete(recursive: true);
      return const Success(null);
    } catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to clear account attachment files.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<String>> saveDownload({
    required String userId,
    required String originalName,
    required Uint8List bytes,
  }) async {
    try {
      final userDirectory = await _userDirectory(userId);
      final downloads = Directory(
        '${userDirectory.path}${Platform.pathSeparator}downloads',
      );
      await downloads.create(recursive: true);
      final safeName = _safeFilename(originalName);
      final path =
          '${downloads.path}${Platform.pathSeparator}${_idFactory()}-$safeName';
      final temporary = File('$path.tmp');
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(path);
      return Success(path);
    } catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to save downloaded attachment.',
          cause: error,
        ),
      );
    }
  }

  Future<bool> userDirectoryExists(String userId) async {
    return (await _userDirectory(userId, create: false)).exists();
  }

  Failure? _validate(SelectedAttachmentSource selection, int existingCount) {
    final extension = _extension(selection.originalName);
    if (!kAcceptedAttachmentExtensions.contains(extension)) {
      return const ValidationFailure(message: 'Unsupported attachment type.');
    }
    if (!_mimeMatches(extension, selection.mimeType)) {
      return const ValidationFailure(
        message: 'Attachment type does not match its extension.',
      );
    }
    if (selection.fileSize < 0 || selection.fileSize > _maximumFileSize) {
      return const ValidationFailure(
        message: 'Attachment exceeds the 10 MiB limit.',
      );
    }
    if (existingCount >= _maximumAttachmentCount) {
      return const ValidationFailure(
        message: 'Attachment count limit reached.',
      );
    }
    if (selection.path.trim().isEmpty) {
      return const ValidationFailure(message: 'Attachment path is empty.');
    }
    return null;
  }

  Future<Directory> _attachmentRoot({bool create = true}) async {
    final root = await _rootDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}rims_attachments',
    );
    if (create) await directory.create(recursive: true);
    return directory;
  }

  Future<Directory> _userDirectory(String userId, {bool create = true}) async {
    final encoded = base64Url.encode(utf8.encode(userId)).replaceAll('=', '');
    final root = await _attachmentRoot(create: create);
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}user_$encoded',
    );
    if (create) await directory.create(recursive: true);
    return directory;
  }

  Future<List<StagedAttachment>> _readManifest(Directory directory) async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}manifest.json',
    );
    if (!await file.exists()) return [];
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?> ||
        decoded['version'] != _manifestVersion ||
        decoded['items'] is! List<Object?>) {
      throw const FormatException('Invalid attachment staging manifest.');
    }
    return (decoded['items']! as List<Object?>)
        .map(_stagedFromJson)
        .toList(growable: false);
  }

  Future<void> _writeManifest(
    Directory directory,
    List<StagedAttachment> items,
  ) async {
    await directory.create(recursive: true);
    final target = File(
      '${directory.path}${Platform.pathSeparator}manifest.json',
    );
    final temporary = File('${target.path}.${_idFactory()}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': _manifestVersion,
        'items': items.map(_stagedToJson).toList(growable: false),
      }),
      flush: true,
    );
    await temporary.rename(target.path);
  }
}

Map<String, Object?> _stagedToJson(StagedAttachment item) => {
  'requestId': item.pending.requestId,
  'businessType': item.pending.binding.businessType,
  'businessId': item.pending.binding.businessId,
  if (item.pending.binding.localDraftId != null)
    'localDraftId': item.pending.binding.localDraftId,
  'stagedPath': item.pending.stagedPath,
  'originalName': item.pending.originalName,
  'mimeType': item.pending.mimeType,
  'fileSize': item.pending.fileSize,
  'thumbnailPath': item.thumbnailPath,
  'createdAt': item.createdAt.toIso8601String(),
};

StagedAttachment _stagedFromJson(Object? raw) {
  if (raw is! Map<String, Object?>) {
    throw const FormatException('Invalid staged attachment entry.');
  }
  final requestId = _requiredString(raw, 'requestId');
  final businessType = _requiredString(raw, 'businessType');
  final businessId = _requiredInt(raw, 'businessId');
  final localDraftId = raw['localDraftId'];
  if (localDraftId != null && localDraftId is! String) {
    throw const FormatException('Invalid staged attachment localDraftId.');
  }
  final createdAt = DateTime.tryParse(_requiredString(raw, 'createdAt'));
  if (createdAt == null) {
    throw const FormatException('Invalid staged attachment timestamp.');
  }
  final thumbnail = raw['thumbnailPath'];
  if (thumbnail != null && thumbnail is! String) {
    throw const FormatException('Invalid staged attachment thumbnail.');
  }
  return StagedAttachment(
    pending: PendingAttachment(
      requestId: requestId,
      binding: AttachmentBinding.fromStorage(
        businessType: businessType,
        businessId: businessId,
        localDraftId: localDraftId as String?,
      ),
      stagedPath: _requiredString(raw, 'stagedPath'),
      originalName: _requiredString(raw, 'originalName'),
      mimeType: _requiredString(raw, 'mimeType'),
      fileSize: _requiredInt(raw, 'fileSize'),
    ),
    thumbnailPath: thumbnail as String?,
    createdAt: createdAt.toUtc(),
  );
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Invalid staged attachment $key.');
  }
  return value;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throw FormatException('Invalid staged attachment $key.');
  }
  return value;
}

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

bool _mimeMatches(String extension, String mimeType) {
  final normalized = mimeType.toLowerCase().split(';').first.trim();
  return switch (extension) {
    'jpg' || 'jpeg' => normalized == 'image/jpeg',
    'png' => normalized == 'image/png',
    'gif' => normalized == 'image/gif',
    'pdf' => normalized == 'application/pdf',
    'csv' =>
      normalized == 'text/csv' ||
          normalized == 'application/csv' ||
          normalized == 'application/vnd.ms-excel',
    'xlsx' =>
      normalized ==
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    _ => false,
  };
}

String _safeFilename(String name) {
  final sanitized = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return sanitized.isEmpty ? 'attachment' : sanitized;
}

Future<void> _defaultCopy(String source, String destination) async {
  await File(source).copy(destination);
}

Future<void> _deleteIfExists(File file) async {
  if (await file.exists()) await file.delete();
}

Future<void> _deleteFilesOlderThan(Directory directory, DateTime cutoff) async {
  if (!await directory.exists()) return;
  await for (final entity in directory.list()) {
    if (entity is! File) continue;
    final modifiedAt = await entity.lastModified();
    if (modifiedAt.toUtc().isBefore(cutoff)) await entity.delete();
  }
}

Future<String?> buildBoundedThumbnail(String source, String destination) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(source);
  final codec = await ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (width, height) {
      if (width <= _thumbnailLongestSide && height <= _thumbnailLongestSide) {
        return ui.TargetImageSize(width: width, height: height);
      }
      final scale = _thumbnailLongestSide / (width > height ? width : height);
      return ui.TargetImageSize(
        width: (width * scale).round(),
        height: (height * scale).round(),
      );
    },
  );
  try {
    final frame = await codec.getNextFrame();
    final bytes = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    if (bytes == null) throw StateError('Unable to encode thumbnail.');
    await File(
      destination,
    ).writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    return destination;
  } finally {
    codec.dispose();
  }
}
