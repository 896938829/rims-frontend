import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../offline/domain/services/offline_ownership_service.dart';
import '../../../offline/domain/services/offline_write_barrier.dart';
import '../../domain/entities/attachment.dart';
import '../../domain/services/attachment_picker.dart';
import '../../domain/services/attachment_staging_store.dart';
import 'android_attachment_picker.dart';

const int _manifestVersion = 1;
const int _maximumFileSize = 10 * 1024 * 1024;
const int _maximumAttachmentCount = 9;
const int _thumbnailLongestSide = 512;
const String _pendingCleanupFilename = 'pending_cleanup.json';

typedef DirectoryProvider = Future<Directory> Function();
typedef FileCopier = Future<void> Function(String source, String destination);
typedef FileDeleter = Future<void> Function(File file);
typedef ManifestCommitter = Future<void> Function(File temporary, File target);
typedef ManifestReadObserver = Future<void> Function(File manifest);
typedef AttachmentFileStreamReader =
    Stream<List<int>> Function(File file, int start, int end);
typedef ThumbnailBuilder =
    Future<String?> Function(String source, String destination);

final class FileAttachmentStagingStore
    implements
        AttachmentStagingStore,
        DraftAttachmentStagingStore,
        OutboxAttachmentStagingStore,
        OutboxAttachmentUploadStagingStore,
        OfflineOwnedFileStore {
  static final _accountOperations = _AsyncKeyedLock();

  FileAttachmentStagingStore({
    required DirectoryProvider rootDirectory,
    required String Function() idFactory,
    DateTime Function()? clock,
    FileCopier? copyFile,
    FileDeleter? deleteFile,
    ManifestCommitter? commitManifest,
    ManifestReadObserver? onManifestRead,
    AttachmentFileStreamReader? openRead,
    ThumbnailBuilder? thumbnailBuilder,
    OfflineWriteBarrier? writeBarrier,
  }) : this._(
         rootDirectory,
         idFactory,
         clock ?? DateTime.now,
         copyFile ?? _defaultCopy,
         deleteFile ?? _deleteIfExists,
         commitManifest ?? _defaultCommitManifest,
         onManifestRead,
         openRead ?? _defaultOpenRead,
         thumbnailBuilder ?? buildBoundedThumbnail,
         writeBarrier,
       );

  FileAttachmentStagingStore._(
    this._rootDirectory,
    this._idFactory,
    this._clock,
    this._copyFile,
    this._deleteFile,
    this._commitManifest,
    this._onManifestRead,
    this._openRead,
    this._thumbnailBuilder,
    this.writeBarrier,
  );

  final DirectoryProvider _rootDirectory;
  final String Function() _idFactory;
  final DateTime Function() _clock;
  final FileCopier _copyFile;
  final FileDeleter _deleteFile;
  final ManifestCommitter _commitManifest;
  final ManifestReadObserver? _onManifestRead;
  final AttachmentFileStreamReader _openRead;
  final ThumbnailBuilder _thumbnailBuilder;
  final OfflineWriteBarrier? writeBarrier;

  @override
  Future<Result<StagedAttachment>> stage({
    required String userId,
    required AttachmentBinding binding,
    required SelectedAttachmentSource selection,
    required int existingCount,
  }) => _withUserLock(
    userId,
    () => _stage(
      userId: userId,
      binding: binding,
      selection: selection,
      existingCount: existingCount,
    ),
  );

  Future<Result<StagedAttachment>> _stage({
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
      await _completePendingCleanup(userDirectory);
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
        sha256: await _sha256File(File(stagedPath)),
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
  Future<Result<List<StagedAttachment>>> recoverForUser(String userId) =>
      _withUserLock(userId, () => _recoverForUser(userId));

  Future<Result<List<StagedAttachment>>> _recoverForUser(String userId) async {
    try {
      final directory = await _userDirectory(userId, create: false);
      if (!await directory.exists()) return const Success([]);
      await _completePendingCleanup(directory);
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
  Future<Result<StagedAttachment>> loadStaged({
    required String userId,
    required String requestId,
  }) => _withUserLock(userId, () => _loadStaged(userId, requestId));

  Future<Result<StagedAttachment>> _loadStaged(
    String userId,
    String requestId,
  ) async {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(requestId)) {
      return const FailureResult(
        ValidationFailure(message: 'Invalid staged attachment request ID.'),
      );
    }
    try {
      final directory = await _userDirectory(userId, create: false);
      if (!await directory.exists()) {
        return const FailureResult(
          ValidationFailure(message: 'Staged attachment is missing.'),
        );
      }
      await _completePendingCleanup(directory);
      final items = await _readManifest(directory);
      final matches = items
          .where((item) => item.pending.requestId == requestId)
          .toList(growable: false);
      if (matches.length != 1) {
        return const FailureResult(
          ValidationFailure(message: 'Staged attachment is missing.'),
        );
      }
      final item = matches.single;
      final file = File(item.pending.stagedPath);
      if (!await file.exists()) {
        return const FailureResult(
          ValidationFailure(message: 'Staged attachment is missing.'),
        );
      }
      final actualSize = await file.length();
      final actualHash = await _sha256File(file);
      if (actualSize != item.pending.fileSize ||
          (item.sha256.isNotEmpty && actualHash != item.sha256)) {
        return const FailureResult(
          ValidationFailure(message: 'Staged attachment changed after review.'),
        );
      }
      if (item.sha256.isEmpty) {
        final upgraded = StagedAttachment(
          pending: item.pending,
          thumbnailPath: item.thumbnailPath,
          createdAt: item.createdAt,
          sha256: actualHash,
        );
        await _writeManifest(directory, [
          for (final candidate in items)
            if (identical(candidate, item)) upgraded else candidate,
        ]);
        return Success(upgraded);
      }
      return Success(item);
    } on Object catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to load staged attachment.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<AttachmentUploadSnapshot>> prepareUploadSnapshot({
    required String userId,
    required String requestId,
    required int expectedSize,
    required String expectedSha256,
    required String? localAggregateId,
    required int? documentId,
  }) => _withUserLock(
    userId,
    () => _prepareUploadSnapshot(
      userId: userId,
      requestId: requestId,
      expectedSize: expectedSize,
      expectedSha256: expectedSha256,
      localAggregateId: localAggregateId,
      documentId: documentId,
    ),
  );

  Future<Result<AttachmentUploadSnapshot>> _prepareUploadSnapshot({
    required String userId,
    required String requestId,
    required int expectedSize,
    required String expectedSha256,
    required String? localAggregateId,
    required int? documentId,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(requestId) ||
        expectedSize < 0 ||
        expectedSize > _maximumFileSize ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha256) ||
        (localAggregateId == null && documentId != null) ||
        (localAggregateId != null &&
            (localAggregateId.trim().isEmpty ||
                documentId == null ||
                documentId <= 0))) {
      return const FailureResult(
        ValidationFailure(message: 'Invalid attachment upload snapshot.'),
      );
    }
    try {
      final directory = await _userDirectory(userId, create: false);
      if (!await directory.exists()) {
        return const FailureResult(
          ValidationFailure(message: 'Staged attachment is missing.'),
        );
      }
      await _completePendingCleanup(directory);
      final items = await _readManifest(directory);
      final matches = items
          .where((item) => item.pending.requestId == requestId)
          .toList(growable: false);
      if (matches.length != 1) {
        return const FailureResult(
          ValidationFailure(message: 'Staged attachment is missing.'),
        );
      }
      final item = matches.single;
      final canonicalPath = await _ownedCanonicalStagedPath(directory, item);
      if (canonicalPath == null) {
        return const FailureResult(
          ValidationFailure(message: 'Staged attachment path is not owned.'),
        );
      }
      final file = File(canonicalPath);
      late final FileStat stat;
      late final _BoundedAttachmentRead read;
      try {
        stat = await file.stat();
        if (stat.type != FileSystemEntityType.file ||
            stat.size < 0 ||
            stat.size > _maximumFileSize ||
            stat.size != expectedSize ||
            stat.size != item.pending.fileSize) {
          return const FailureResult(
            ValidationFailure(
              message: 'Staged attachment changed after review.',
            ),
          );
        }
        read = await _readBoundedAttachment(file, expectedSize);
      } on FileSystemException catch (error) {
        return FailureResult(
          ValidationFailure(
            message: 'Staged attachment is missing or changed.',
            cause: error,
          ),
        );
      }
      if (read.overflow ||
          read.bytes.length != expectedSize ||
          read.sha256 != expectedSha256 ||
          item.sha256 != expectedSha256) {
        return const FailureResult(
          ValidationFailure(message: 'Staged attachment changed after review.'),
        );
      }

      final binding = item.pending.binding;
      final isDraft = localAggregateId != null;
      final isOwnedDraft =
          binding.businessType == 'document_draft' &&
          binding.localDraftId == localAggregateId;
      final isAuthoritative =
          binding.businessType == 'doc_attachment' &&
          binding.businessId > 0 &&
          binding.localDraftId == null;
      final isExactReplay =
          isDraft && isAuthoritative && binding.businessId == documentId;
      if ((isDraft && !isOwnedDraft && !isExactReplay) ||
          (!isDraft && !isAuthoritative)) {
        return const FailureResult(
          ValidationFailure(
            message: 'Draft attachment ownership changed before upload.',
          ),
        );
      }

      final pending = PendingAttachment(
        requestId: item.pending.requestId,
        binding: isDraft
            ? AttachmentBinding.document(documentId!)
            : item.pending.binding,
        stagedPath: canonicalPath,
        originalName: item.pending.originalName,
        mimeType: item.pending.mimeType,
        fileSize: item.pending.fileSize,
      );
      if (isOwnedDraft) {
        final rebound = StagedAttachment(
          pending: pending,
          thumbnailPath: item.thumbnailPath,
          createdAt: item.createdAt,
          sha256: item.sha256,
        );
        await _writeManifest(directory, [
          for (final candidate in items)
            if (identical(candidate, item)) rebound else candidate,
        ]);
      }
      return Success(
        AttachmentUploadSnapshot(pending: pending, bytes: read.bytes),
      );
    } on Object catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to prepare staged attachment upload.',
          cause: error,
        ),
      );
    }
  }

  Future<_BoundedAttachmentRead> _readBoundedAttachment(
    File file,
    int expectedSize,
  ) async {
    final readLimit = expectedSize + 1;
    final bytes = BytesBuilder(copy: false);
    final digestCapture = _DigestCapture();
    final hashSink = sha256.startChunkedConversion(digestCapture);
    var observed = 0;
    var stored = 0;
    try {
      await for (final chunk in _openRead(file, 0, readLimit)) {
        if (observed >= readLimit) break;
        final observedInChunk = chunk.length <= readLimit - observed
            ? chunk.length
            : readLimit - observed;
        final dataInChunk = observedInChunk <= expectedSize - stored
            ? observedInChunk
            : expectedSize - stored;
        if (dataInChunk > 0) {
          final accepted = dataInChunk == chunk.length
              ? chunk
              : chunk.sublist(0, dataInChunk);
          bytes.add(accepted);
          hashSink.add(accepted);
          stored += dataInChunk;
        }
        observed += observedInChunk;
      }
    } finally {
      hashSink.close();
    }
    return _BoundedAttachmentRead(
      bytes: bytes.takeBytes(),
      sha256: digestCapture.digest.toString(),
      overflow: observed > expectedSize,
    );
  }

  @override
  Future<Result<void>> rebindDocumentDraft({
    required String userId,
    required String localAggregateId,
    required int documentId,
    required List<String> requestIds,
  }) => _withUserLock(
    userId,
    () => _rebindDocumentDraft(
      userId: userId,
      localAggregateId: localAggregateId,
      documentId: documentId,
      requestIds: requestIds,
    ),
  );

  Future<Result<void>> _rebindDocumentDraft({
    required String userId,
    required String localAggregateId,
    required int documentId,
    required List<String> requestIds,
  }) async {
    if (localAggregateId.trim().isEmpty ||
        documentId <= 0 ||
        requestIds.toSet().length != requestIds.length) {
      return const FailureResult(
        ValidationFailure(message: 'Invalid document attachment rebind.'),
      );
    }
    if (requestIds.isEmpty) return const Success(null);
    try {
      final directory = await _userDirectory(userId, create: false);
      if (!await directory.exists()) {
        return const FailureResult(
          ValidationFailure(message: 'Staged attachments are missing.'),
        );
      }
      await _completePendingCleanup(directory);
      final items = await _readManifest(directory);
      final requested = requestIds.toSet();
      final selected = items.where(
        (item) => requested.contains(item.pending.requestId),
      );
      if (selected.length != requested.length ||
          selected.any((item) {
            final binding = item.pending.binding;
            final isOwnedDraft =
                binding.businessType == 'document_draft' &&
                binding.localDraftId == localAggregateId;
            final isExactReplay =
                binding.businessType == 'doc_attachment' &&
                binding.businessId == documentId &&
                binding.localDraftId == null;
            return !isOwnedDraft && !isExactReplay;
          })) {
        return const FailureResult(
          ValidationFailure(
            message: 'Draft attachment ownership changed before rebind.',
          ),
        );
      }
      final rebound = items
          .map(
            (item) => !requested.contains(item.pending.requestId)
                ? item
                : StagedAttachment(
                    pending: PendingAttachment(
                      requestId: item.pending.requestId,
                      binding: AttachmentBinding.document(documentId),
                      stagedPath: item.pending.stagedPath,
                      originalName: item.pending.originalName,
                      mimeType: item.pending.mimeType,
                      fileSize: item.pending.fileSize,
                    ),
                    thumbnailPath: item.thumbnailPath,
                    createdAt: item.createdAt,
                    sha256: item.sha256,
                  ),
          )
          .toList(growable: false);
      await _writeManifest(directory, rebound);
      return const Success(null);
    } on Object catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to rebind draft attachments.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<List<StagedAttachment>>> duplicateDraftAttachments({
    required String userId,
    required String sourceDraftId,
    required String targetDraftId,
    required List<String> requestIds,
  }) => _withUserLock(
    userId,
    () => _duplicateDraftAttachments(
      userId: userId,
      sourceDraftId: sourceDraftId,
      targetDraftId: targetDraftId,
      requestIds: requestIds,
    ),
  );

  Future<Result<List<StagedAttachment>>> _duplicateDraftAttachments({
    required String userId,
    required String sourceDraftId,
    required String targetDraftId,
    required List<String> requestIds,
  }) async {
    if (requestIds.isEmpty) return const Success([]);
    final createdFiles = <File>[];
    try {
      final directory = await _userDirectory(userId, create: false);
      if (!await directory.exists()) {
        throw const FileSystemException('Attachment owner directory missing.');
      }
      await _completePendingCleanup(directory);
      final current = await _readManifest(directory);
      final requested = requestIds.toSet();
      if (requested.length != requestIds.length) {
        throw const FormatException('Duplicate attachment request IDs.');
      }
      final sources = current
          .where(
            (item) =>
                requested.contains(item.pending.requestId) &&
                item.pending.binding.localDraftId == sourceDraftId,
          )
          .toList(growable: false);
      if (sources.length != requestIds.length) {
        throw const FileSystemException('Draft attachment source missing.');
      }
      final targetCount = current
          .where((item) => item.pending.binding.localDraftId == targetDraftId)
          .length;
      if (targetCount + sources.length > _maximumAttachmentCount) {
        throw const FileSystemException('Attachment count limit reached.');
      }
      final stagedDirectory = Directory(
        '${directory.path}${Platform.pathSeparator}staged',
      );
      final thumbnailsDirectory = Directory(
        '${directory.path}${Platform.pathSeparator}thumbnails',
      );
      await stagedDirectory.create(recursive: true);
      final knownIds = current.map((item) => item.pending.requestId).toSet();
      final duplicates = <StagedAttachment>[];
      for (final source in sources) {
        final requestId = _idFactory();
        if (!knownIds.add(requestId)) {
          throw const FileSystemException(
            'Attachment staging identifier collision.',
          );
        }
        final stagedPath =
            '${stagedDirectory.path}${Platform.pathSeparator}$requestId.${_extension(source.pending.originalName)}';
        final stagedFile = File(stagedPath);
        if (await stagedFile.exists()) {
          throw const FileSystemException(
            'Attachment staging identifier collision.',
          );
        }
        createdFiles.add(stagedFile);
        await _copyFile(source.pending.stagedPath, stagedPath);
        String? thumbnailPath;
        final sourceThumbnail = source.thumbnailPath;
        if (sourceThumbnail != null && await File(sourceThumbnail).exists()) {
          await thumbnailsDirectory.create(recursive: true);
          thumbnailPath =
              '${thumbnailsDirectory.path}${Platform.pathSeparator}$requestId.png';
          final thumbnail = File(thumbnailPath);
          createdFiles.add(thumbnail);
          await _copyFile(sourceThumbnail, thumbnailPath);
        }
        duplicates.add(
          StagedAttachment(
            pending: PendingAttachment(
              requestId: requestId,
              binding: AttachmentBinding.documentDraft(targetDraftId),
              stagedPath: stagedPath,
              originalName: source.pending.originalName,
              mimeType: source.pending.mimeType,
              fileSize: await stagedFile.length(),
            ),
            thumbnailPath: thumbnailPath,
            createdAt: _clock().toUtc(),
            sha256: await _sha256File(stagedFile),
          ),
        );
      }
      await _writeManifest(directory, [...current, ...duplicates]);
      return Success(List.unmodifiable(duplicates));
    } catch (error) {
      for (final file in createdFiles.reversed) {
        await _deleteIfExists(file);
      }
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to duplicate draft attachments.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void>> removeStagedAttachments({
    required String userId,
    required List<String> requestIds,
  }) => _withUserLock(
    userId,
    () => _removeStagedAttachments(userId: userId, requestIds: requestIds),
  );

  Future<Result<void>> _removeStagedAttachments({
    required String userId,
    required List<String> requestIds,
  }) async {
    if (requestIds.isEmpty) return const Success(null);
    var cleanupIntentPersisted = false;
    try {
      final directory = await _userDirectory(userId, create: false);
      if (!await directory.exists()) return const Success(null);
      final pending = await _readPendingCleanup(directory)
        ..addAll(requestIds);
      await _writePendingCleanup(directory, pending);
      cleanupIntentPersisted = true;
      await _completePendingCleanup(directory);
      return const Success(null);
    } catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: cleanupIntentPersisted
              ? 'Unable to remove duplicated draft attachments. Cleanup is pending and will retry.'
              : 'Unable to remove duplicated draft attachments. Cleanup intent could not be persisted.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<void>> remove(String userId, String requestId) =>
      _withUserLock(userId, () => _remove(userId, requestId));

  Future<Result<void>> _remove(String userId, String requestId) async {
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
  Future<Result<void>> cleanupStale({
    required String userId,
    required Duration maxAge,
    Set<String> protectedRequestIds = const {},
  }) => _withUserLock(
    userId,
    () => _cleanupStale(
      userId: userId,
      maxAge: maxAge,
      protectedRequestIds: protectedRequestIds,
    ),
  );

  Future<Result<void>> _cleanupStale({
    required String userId,
    required Duration maxAge,
    required Set<String> protectedRequestIds,
  }) async {
    try {
      final directory = await _userDirectory(userId, create: false);
      if (!await directory.exists()) return const Success(null);
      final cutoff = _clock().toUtc().subtract(maxAge);
      if (!await directory.exists()) return const Success(null);
      await _completePendingCleanup(directory);
      final items = await _readManifest(directory);
      final retained = <StagedAttachment>[];
      for (final item in items) {
        if (item.createdAt.isBefore(cutoff) &&
            !protectedRequestIds.contains(item.pending.requestId)) {
          await _deleteIfExists(File(item.pending.stagedPath));
          final thumbnail = item.thumbnailPath;
          if (thumbnail != null) await _deleteIfExists(File(thumbnail));
        } else {
          retained.add(item);
        }
      }
      await _writeManifest(directory, retained);
      await _deleteFilesOlderThan(
        Directory('${directory.path}${Platform.pathSeparator}downloads'),
        cutoff,
      );
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
  Future<Result<void>> clearForUser(String userId) =>
      _withUserLock(userId, () => _clearForUser(userId));

  Future<Result<void>> _clearForUser(String userId) async {
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
  }) => _withUserLock(
    userId,
    () =>
        _saveDownload(userId: userId, originalName: originalName, bytes: bytes),
  );

  Future<Result<String>> _saveDownload({
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

  @override
  Future<OfflineFileOwnershipSnapshot> inspectAccount(String accountId) {
    return _withUserLock(accountId, () async {
      final recovered = await _recoverForUser(accountId);
      final staged = recovered.when(
        success: (items) => items.length,
        failure: (failure) => throw StateError(failure.message),
      );
      final directory = await _userDirectory(accountId, create: false);
      final downloads = Directory(
        '${directory.path}${Platform.pathSeparator}downloads',
      );
      var downloadCount = 0;
      if (await downloads.exists()) {
        await for (final entity in downloads.list()) {
          if (entity is File && !entity.path.endsWith('.tmp')) {
            downloadCount += 1;
          }
        }
      }
      return OfflineFileOwnershipSnapshot(
        stagedTransfers: staged,
        downloads: downloadCount,
      );
    }, privileged: true);
  }

  @override
  Future<void> clearAccountFiles(
    String accountId, {
    required Set<String> retainStagedRequestIds,
  }) {
    return _withUserLock(accountId, () async {
      if (retainStagedRequestIds.isEmpty) {
        final result = await _clearForUser(accountId);
        result.when(
          success: (_) {},
          failure: (failure) => throw StateError(failure.message),
        );
        return;
      }
      final directory = await _userDirectory(accountId, create: false);
      if (!await directory.exists()) return;
      await _completePendingCleanup(directory);
      final items = await _readManifest(directory);
      final retained = <StagedAttachment>[];
      for (final item in items) {
        if (retainStagedRequestIds.contains(item.pending.requestId) &&
            await File(item.pending.stagedPath).exists()) {
          retained.add(item);
        } else {
          await _deleteFile(File(item.pending.stagedPath));
          final thumbnail = item.thumbnailPath;
          if (thumbnail != null) await _deleteFile(File(thumbnail));
        }
      }
      final retainedPaths = <String>{
        for (final item in retained)
          File(item.pending.stagedPath).absolute.path,
        for (final item in retained)
          if (item.thumbnailPath != null)
            File(item.thumbnailPath!).absolute.path,
      };
      for (final name in const ['staged', 'thumbnails']) {
        final ownedDirectory = Directory(
          '${directory.path}${Platform.pathSeparator}$name',
        );
        if (!await ownedDirectory.exists()) continue;
        await for (final entity in ownedDirectory.list()) {
          if (entity is File && !retainedPaths.contains(entity.absolute.path)) {
            await _deleteFile(entity);
          }
        }
      }
      await _writeManifest(directory, retained);
      final downloads = Directory(
        '${directory.path}${Platform.pathSeparator}downloads',
      );
      if (await downloads.exists()) await downloads.delete(recursive: true);
    }, privileged: true);
  }

  @override
  Future<void> clearDownloads(String accountId) {
    return _withUserLock(accountId, () async {
      final directory = await _userDirectory(accountId, create: false);
      final downloads = Directory(
        '${directory.path}${Platform.pathSeparator}downloads',
      );
      if (await downloads.exists()) await downloads.delete(recursive: true);
    }, privileged: true);
  }

  @override
  Future<void> clearStagedTransfers(String accountId) {
    return _withUserLock(accountId, () async {
      final directory = await _userDirectory(accountId, create: false);
      if (!await directory.exists()) return;
      for (final name in const ['staged', 'thumbnails']) {
        final ownedDirectory = Directory(
          '${directory.path}${Platform.pathSeparator}$name',
        );
        if (await ownedDirectory.exists()) {
          await ownedDirectory.delete(recursive: true);
        }
      }
      for (final name in const [
        'manifest.json',
        'manifest.json.tmp',
        _pendingCleanupFilename,
      ]) {
        await _deleteIfExists(
          File('${directory.path}${Platform.pathSeparator}$name'),
        );
      }
    }, privileged: true);
  }

  @override
  Future<void> clearAllFiles() async {
    final root = await _attachmentRoot(create: false);
    await _accountOperations.run(root.absolute.path, () async {
      if (await root.exists()) await root.delete(recursive: true);
    });
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

  Future<T> _withUserLock<T>(
    String userId,
    Future<T> Function() operation, {
    bool privileged = false,
  }) {
    Future<T> locked() async {
      final directory = await _userDirectory(userId, create: false);
      return _accountOperations.run(directory.absolute.path, operation);
    }

    final barrier = writeBarrier;
    return privileged || barrier == null
        ? Future<T>.sync(locked)
        : barrier.protect(accountId: userId, operation: locked);
  }

  Future<List<StagedAttachment>> _readManifest(Directory directory) async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}manifest.json',
    );
    if (!await file.exists()) {
      await _onManifestRead?.call(file);
      return [];
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?> ||
        decoded['version'] != _manifestVersion ||
        decoded['items'] is! List<Object?>) {
      throw const FormatException('Invalid attachment staging manifest.');
    }
    final rawItems = decoded['items']! as List<Object?>;
    final items = <StagedAttachment>[];
    for (final raw in rawItems) {
      try {
        final item = _stagedFromJson(raw);
        if (await _isTrustedManifestItem(directory, item)) items.add(item);
      } on Object {
        // Invalid persisted entries are excluded from every file operation.
      }
    }
    await _onManifestRead?.call(file);
    if (items.length != rawItems.length) {
      await _writeManifest(directory, items);
    }
    return items;
  }

  Future<bool> _isTrustedManifestItem(
    Directory directory,
    StagedAttachment item,
  ) async {
    final requestId = item.pending.requestId;
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(requestId)) return false;
    final extension = _extension(item.pending.originalName);
    if (!kAcceptedAttachmentExtensions.contains(extension)) return false;
    final stagedRoot = Directory(
      '${directory.path}${Platform.pathSeparator}staged',
    );
    if (!await _matchesOwnedPath(
      path: item.pending.stagedPath,
      root: stagedRoot,
      expectedFilename: '$requestId.$extension',
    )) {
      return false;
    }
    final thumbnail = item.thumbnailPath;
    if (thumbnail == null) return true;
    return _matchesOwnedPath(
      path: thumbnail,
      root: Directory('${directory.path}${Platform.pathSeparator}thumbnails'),
      expectedFilename: '$requestId.png',
    );
  }

  Future<String?> _ownedCanonicalStagedPath(
    Directory directory,
    StagedAttachment item,
  ) async {
    final extension = _extension(item.pending.originalName);
    final stagedRoot = Directory(
      '${directory.path}${Platform.pathSeparator}staged',
    );
    final canonicalRoot = await _canonicalPath(stagedRoot);
    final canonicalFile = await _canonicalPath(File(item.pending.stagedPath));
    final comparableRoot = _comparablePath(canonicalRoot);
    final comparableFile = _comparablePath(canonicalFile);
    if (_filename(canonicalFile) != '${item.pending.requestId}.$extension' ||
        !comparableFile.startsWith(
          '$comparableRoot${Platform.pathSeparator}',
        )) {
      return null;
    }
    return canonicalFile;
  }

  Future<bool> _matchesOwnedPath({
    required String path,
    required Directory root,
    required String expectedFilename,
  }) async {
    final canonicalRoot = await _canonicalPath(root);
    final canonicalFile = await _canonicalPath(File(path));
    final comparableRoot = _comparablePath(canonicalRoot);
    final comparableFile = _comparablePath(canonicalFile);
    return _filename(canonicalFile) == expectedFilename &&
        comparableFile.startsWith('$comparableRoot${Platform.pathSeparator}');
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
    try {
      await temporary.writeAsString(
        jsonEncode({
          'version': _manifestVersion,
          'items': items.map(_stagedToJson).toList(growable: false),
        }),
        flush: true,
      );
      await _commitManifest(temporary, target);
    } catch (_) {
      await _deleteIfExists(temporary);
      rethrow;
    }
  }

  Future<Set<String>> _readPendingCleanup(Directory directory) async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}$_pendingCleanupFilename',
    );
    if (!await file.exists()) return <String>{};
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?> ||
        decoded['version'] != _manifestVersion ||
        decoded['requestIds'] is! List<Object?>) {
      throw const FormatException('Invalid attachment cleanup intent.');
    }
    final requestIds = decoded['requestIds']! as List<Object?>;
    if (requestIds.any((item) => item is! String || item.isEmpty)) {
      throw const FormatException('Invalid attachment cleanup request ID.');
    }
    return requestIds.cast<String>().toSet();
  }

  Future<void> _writePendingCleanup(
    Directory directory,
    Set<String> requestIds,
  ) async {
    final target = File(
      '${directory.path}${Platform.pathSeparator}$_pendingCleanupFilename',
    );
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': _manifestVersion,
        'requestIds': requestIds.toList(growable: false),
      }),
      flush: true,
    );
    await temporary.rename(target.path);
  }

  Future<void> _completePendingCleanup(Directory directory) async {
    final requested = await _readPendingCleanup(directory);
    if (requested.isEmpty) return;
    final items = await _readManifest(directory);
    final retained = <StagedAttachment>[];
    for (final item in items) {
      if (requested.contains(item.pending.requestId)) {
        await _deleteFile(File(item.pending.stagedPath));
        final thumbnail = item.thumbnailPath;
        if (thumbnail != null) await _deleteFile(File(thumbnail));
      } else {
        retained.add(item);
      }
    }
    await _deleteFilesForRequestIds(directory, requested);
    await _writeManifest(directory, retained);
    final verified = await _readManifest(directory);
    if (verified.any((item) => requested.contains(item.pending.requestId))) {
      throw const FileSystemException(
        'Attachment cleanup manifest verification failed.',
      );
    }
    if (await _hasFilesForRequestIds(directory, requested)) {
      throw const FileSystemException(
        'Attachment cleanup file verification failed.',
      );
    }
    await _deleteIfExists(
      File(
        '${directory.path}${Platform.pathSeparator}$_pendingCleanupFilename',
      ),
    );
  }

  Future<void> _deleteFilesForRequestIds(
    Directory directory,
    Set<String> requestIds,
  ) async {
    for (final name in const ['staged', 'thumbnails']) {
      final files = Directory(
        '${directory.path}${Platform.pathSeparator}$name',
      );
      if (!await files.exists()) continue;
      await for (final entity in files.list()) {
        if (entity is File &&
            requestIds.any(
              (requestId) =>
                  _filename(entity.path) == requestId ||
                  _filename(entity.path).startsWith('$requestId.'),
            )) {
          await _deleteFile(entity);
        }
      }
    }
  }

  Future<bool> _hasFilesForRequestIds(
    Directory directory,
    Set<String> requestIds,
  ) async {
    for (final name in const ['staged', 'thumbnails']) {
      final files = Directory(
        '${directory.path}${Platform.pathSeparator}$name',
      );
      if (!await files.exists()) continue;
      await for (final entity in files.list()) {
        final filename = _filename(entity.path);
        if (entity is File &&
            requestIds.any(
              (requestId) =>
                  filename == requestId || filename.startsWith('$requestId.'),
            )) {
          return true;
        }
      }
    }
    return false;
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
  if (item.sha256.isNotEmpty) 'sha256': item.sha256,
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
  final persistedHash = raw['sha256'];
  if (persistedHash != null &&
      (persistedHash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(persistedHash))) {
    throw const FormatException('Invalid staged attachment sha256.');
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
    sha256: persistedHash as String? ?? '',
  );
}

Future<String> _sha256File(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
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

Stream<List<int>> _defaultOpenRead(File file, int start, int end) =>
    file.openRead(start, end);

Future<void> _defaultCommitManifest(File temporary, File target) async {
  await temporary.rename(target.path);
}

Future<void> _deleteIfExists(File file) async {
  if (await file.exists()) await file.delete();
}

String _filename(String path) => path.split(Platform.pathSeparator).last;

Future<String> _canonicalPath(FileSystemEntity entity) async {
  try {
    if (await entity.exists()) return await entity.resolveSymbolicLinks();
  } on FileSystemException {
    return _normalizeAbsolutePath(entity.path);
  }
  return _normalizeAbsolutePath(entity.path);
}

String _normalizeAbsolutePath(String path) => Uri.file(
  File(path).absolute.path,
  windows: Platform.isWindows,
).normalizePath().toFilePath(windows: Platform.isWindows);

String _comparablePath(String path) =>
    Platform.isWindows ? path.toLowerCase() : path;

Future<void> _deleteFilesOlderThan(Directory directory, DateTime cutoff) async {
  if (!await directory.exists()) return;
  await for (final entity in directory.list()) {
    if (entity is! File) continue;
    final modifiedAt = await entity.lastModified();
    if (modifiedAt.toUtc().isBefore(cutoff)) await entity.delete();
  }
}

final class _AsyncKeyedLock {
  final Map<String, Future<void>> _tails = {};

  Future<T> run<T>(String rawKey, Future<T> Function() operation) async {
    final key = _comparablePath(_normalizeAbsolutePath(rawKey));
    final previous = _tails[key] ?? Future<void>.value();
    final release = Completer<void>();
    final tail = release.future;
    _tails[key] = tail;
    await previous;
    try {
      return await operation();
    } finally {
      release.complete();
      if (identical(_tails[key], tail)) _tails.remove(key);
    }
  }
}

final class _BoundedAttachmentRead {
  const _BoundedAttachmentRead({
    required this.bytes,
    required this.sha256,
    required this.overflow,
  });

  final Uint8List bytes;
  final String sha256;
  final bool overflow;
}

final class _DigestCapture implements Sink<Digest> {
  late Digest digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
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
