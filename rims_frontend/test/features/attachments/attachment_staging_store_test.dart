import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/attachments/data/services/file_attachment_staging_store.dart';
import 'package:rims_frontend/features/attachments/domain/entities/attachment.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_picker.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/services/attachment_staging_protection.dart';

void main() {
  late Directory root;
  late File source;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rims_stage_test_');
    source = File('${root.path}${Platform.pathSeparator}source.jpg');
    await source.writeAsBytes(Uint8List.fromList([1, 2, 3, 4]));
  });

  tearDown(() => root.delete(recursive: true));

  FileAttachmentStagingStore store({
    FileCopier? copyFile,
    FileDeleter? deleteFile,
    ManifestCommitter? commitManifest,
    ManifestReadObserver? onManifestRead,
    AttachmentFileStreamReader? openRead,
    DateTime? now,
    String Function()? idFactory,
  }) {
    return FileAttachmentStagingStore(
      rootDirectory: () async => root,
      idFactory: idFactory ?? () => 'request-1',
      clock: () => now ?? DateTime.utc(2026, 7, 13),
      copyFile: copyFile,
      deleteFile: deleteFile,
      commitManifest: commitManifest,
      onManifestRead: onManifestRead,
      openRead: openRead,
      thumbnailBuilder: (sourcePath, destinationPath) async {
        await File(destinationPath).writeAsBytes([9, 8, 7]);
        return destinationPath;
      },
    );
  }

  SelectedAttachmentSource selection({
    String? path,
    String name = 'photo.jpg',
    String mime = 'image/jpeg',
    int size = 4,
  }) => SelectedAttachmentSource(
    path: path ?? source.path,
    originalName: name,
    mimeType: mime,
    fileSize: size,
  );

  test(
    'stages to an owned collision-safe path and atomically recovers manifest',
    () async {
      final first = store();
      final result = await first.stage(
        userId: '42',
        binding: AttachmentBinding.document(9),
        selection: selection(),
        existingCount: 0,
      );

      late String stagedPath;
      result.when(
        success: (staged) {
          stagedPath = staged.pending.stagedPath;
          expect(stagedPath, isNot(source.path));
          expect(File(stagedPath).readAsBytesSync(), [1, 2, 3, 4]);
          expect(File(staged.thumbnailPath!).lengthSync(), greaterThan(0));
        },
        failure: (failure) => fail(failure.message),
      );

      final recovered = await store().recoverForUser('42');
      recovered.when(
        success: (items) {
          expect(items.single.pending.requestId, 'request-1');
          expect(items.single.pending.stagedPath, stagedPath);
        },
        failure: (failure) => fail(failure.message),
      );
    },
  );

  test(
    'document draft binding survives staging-store reconstruction',
    () async {
      await store().stage(
        userId: '42',
        binding: AttachmentBinding.documentDraft('stable-draft-id'),
        selection: selection(),
        existingCount: 0,
      );

      final recovered = await store().recoverForUser('42');

      recovered.when(
        success: (items) {
          expect(items.single.pending.binding.businessType, 'document_draft');
          expect(items.single.pending.binding.localDraftId, 'stable-draft-id');
        },
        failure: (failure) => fail(failure.message),
      );
    },
  );

  test(
    'outbox load survives reconstruction and rebinds only to server id',
    () async {
      await store().stage(
        userId: '42',
        binding: AttachmentBinding.documentDraft('stable-draft-id'),
        selection: selection(),
        existingCount: 0,
      );

      final rebuilt = store();
      final before = await rebuilt.loadStaged(
        userId: '42',
        requestId: 'request-1',
      );
      before.when(
        success: (item) {
          expect(item.sha256, hasLength(64));
          expect(item.pending.binding.localDraftId, 'stable-draft-id');
        },
        failure: (failure) => fail(failure.message),
      );

      final rebound = await rebuilt.rebindDocumentDraft(
        userId: '42',
        localAggregateId: 'stable-draft-id',
        documentId: 91,
        requestIds: const ['request-1'],
      );
      rebound.when(
        success: (_) {},
        failure: (failure) => fail(failure.message),
      );
      final replayedRebind = await store().rebindDocumentDraft(
        userId: '42',
        localAggregateId: 'stable-draft-id',
        documentId: 91,
        requestIds: const ['request-1'],
      );
      replayedRebind.when(
        success: (_) {},
        failure: (failure) => fail(failure.message),
      );
      final after = await store().loadStaged(
        userId: '42',
        requestId: 'request-1',
      );
      after.when(
        success: (item) {
          expect(item.pending.binding, AttachmentBinding.document(91));
          expect(item.pending.binding.localDraftId, isNull);
        },
        failure: (failure) => fail(failure.message),
      );
    },
  );

  test(
    'outbox snapshot validates and rebinds immutable bytes under one lock',
    () async {
      final staged = (await store().stage(
        userId: '42',
        binding: AttachmentBinding.documentDraft('draft-1'),
        selection: selection(),
        existingCount: 0,
      )).successData;

      final snapshot = (await store().prepareUploadSnapshot(
        userId: '42',
        requestId: staged.pending.requestId,
        expectedSize: staged.pending.fileSize,
        expectedSha256: staged.sha256,
        localAggregateId: 'draft-1',
        documentId: 91,
      )).successData;

      expect(snapshot.bytes, [1, 2, 3, 4]);
      expect(snapshot.pending.binding, AttachmentBinding.document(91));
      expect(() => snapshot.bytes[0] = 9, throwsUnsupportedError);
      await File(staged.pending.stagedPath).writeAsBytes([9, 9, 9, 9]);
      expect(snapshot.bytes, [1, 2, 3, 4]);
    },
  );

  test(
    'concurrent staged-file replacement fails before draft rebind',
    () async {
      final staged = (await store().stage(
        userId: '42',
        binding: AttachmentBinding.documentDraft('draft-1'),
        selection: selection(),
        existingCount: 0,
      )).successData;
      final manifestRead = Completer<void>();
      final continueSnapshot = Completer<void>();
      final rebuilt = store(
        onManifestRead: (_) async {
          if (!manifestRead.isCompleted) {
            manifestRead.complete();
            await continueSnapshot.future;
          }
        },
      );

      final pending = rebuilt.prepareUploadSnapshot(
        userId: '42',
        requestId: staged.pending.requestId,
        expectedSize: staged.pending.fileSize,
        expectedSha256: staged.sha256,
        localAggregateId: 'draft-1',
        documentId: 91,
      );
      await manifestRead.future;
      await File(staged.pending.stagedPath).writeAsBytes([7, 7, 7, 7]);
      continueSnapshot.complete();

      expect((await pending).failureOrNull, isA<ValidationFailure>());
      expect(
        (await store().recoverForUser('42')).successData.single.pending.binding,
        AttachmentBinding.documentDraft('draft-1'),
      );
    },
  );

  test(
    'oversized replacement is rejected from stat without opening a byte stream',
    () async {
      var readerCalls = 0;
      final boundedStore = store(
        openRead: (file, start, end) {
          readerCalls += 1;
          return file.openRead(start, end);
        },
      );
      final staged = (await boundedStore.stage(
        userId: '42',
        binding: AttachmentBinding.documentDraft('draft-1'),
        selection: selection(),
        existingCount: 0,
      )).successData;
      final replacement = await File(
        staged.pending.stagedPath,
      ).open(mode: FileMode.write);
      await replacement.truncate(10 * 1024 * 1024 + 1);
      await replacement.close();

      final result = await boundedStore.prepareUploadSnapshot(
        userId: '42',
        requestId: staged.pending.requestId,
        expectedSize: staged.pending.fileSize,
        expectedSha256: staged.sha256,
        localAggregateId: 'draft-1',
        documentId: 91,
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
      expect(readerCalls, 0);
      expect(
        (await store().recoverForUser('42')).successData.single.pending.binding,
        AttachmentBinding.documentDraft('draft-1'),
      );
    },
  );

  test('snapshot stream is bounded to expected size plus one byte', () async {
    int? requestedStart;
    int? requestedEnd;
    final boundedStore = store(
      openRead: (_, start, end) {
        requestedStart = start;
        requestedEnd = end;
        return Stream<List<int>>.value(const [1, 2, 3, 4, 5, 6, 7]);
      },
    );
    final staged = (await boundedStore.stage(
      userId: '42',
      binding: AttachmentBinding.documentDraft('draft-1'),
      selection: selection(),
      existingCount: 0,
    )).successData;

    final result = await boundedStore.prepareUploadSnapshot(
      userId: '42',
      requestId: staged.pending.requestId,
      expectedSize: staged.pending.fileSize,
      expectedSha256: staged.sha256,
      localAggregateId: 'draft-1',
      documentId: 91,
    );

    expect(result.failureOrNull, isA<ValidationFailure>());
    expect(requestedStart, 0);
    expect(requestedEnd, staged.pending.fileSize + 1);
    expect(
      (await store().recoverForUser('42')).successData.single.pending.binding,
      AttachmentBinding.documentDraft('draft-1'),
    );
  });

  test(
    'missing snapshot file is validation and leaves draft binding unchanged',
    () async {
      final staged = (await store().stage(
        userId: '42',
        binding: AttachmentBinding.documentDraft('draft-1'),
        selection: selection(),
        existingCount: 0,
      )).successData;
      await File(staged.pending.stagedPath).delete();

      final result = await store().prepareUploadSnapshot(
        userId: '42',
        requestId: staged.pending.requestId,
        expectedSize: staged.pending.fileSize,
        expectedSha256: staged.sha256,
        localAggregateId: 'draft-1',
        documentId: 91,
      );

      expect(result.failureOrNull, isA<ValidationFailure>());
      final manifest = await root
          .list(recursive: true)
          .where(
            (entity) => entity is File && entity.path.endsWith('manifest.json'),
          )
          .cast<File>()
          .single;
      expect(await manifest.readAsString(), contains('document_draft'));
    },
  );

  test('symlink path swap is rejected before draft rebind', () async {
    final staged = (await store().stage(
      userId: '42',
      binding: AttachmentBinding.documentDraft('draft-1'),
      selection: selection(),
      existingCount: 0,
    )).successData;
    final outside = File('${root.path}${Platform.pathSeparator}outside.pdf');
    await outside.writeAsBytes([1, 2, 3, 4]);
    await File(staged.pending.stagedPath).delete();
    await Link(staged.pending.stagedPath).create(outside.path);

    final result = await store().prepareUploadSnapshot(
      userId: '42',
      requestId: staged.pending.requestId,
      expectedSize: staged.pending.fileSize,
      expectedSha256: staged.sha256,
      localAggregateId: 'draft-1',
      documentId: 91,
    );

    expect(result.failureOrNull, isA<ValidationFailure>());
    expect(await outside.readAsBytes(), [1, 2, 3, 4]);
  });

  test('outbox load rejects missing and changed staged files', () async {
    final staged = await store().stage(
      userId: '42',
      binding: AttachmentBinding.document(91),
      selection: selection(),
      existingCount: 0,
    );
    late final String path;
    staged.when(
      success: (item) => path = item.pending.stagedPath,
      failure: (failure) => fail(failure.message),
    );

    await File(path).writeAsBytes([4, 3, 2, 1], flush: true);
    final changed = await store().loadStaged(
      userId: '42',
      requestId: 'request-1',
    );
    changed.when(
      success: (_) => fail('changed file must not load'),
      failure: (failure) => expect(failure, isA<ValidationFailure>()),
    );

    await File(path).delete();
    final missing = await store().loadStaged(
      userId: '42',
      requestId: 'request-1',
    );
    missing.when(
      success: (_) => fail('missing file must not load'),
      failure: (failure) => expect(failure, isA<ValidationFailure>()),
    );
  });

  test('manifest paths outside the user roots are quarantined', () async {
    final externalFile = File(
      '${root.path}${Platform.pathSeparator}external.pdf',
    )..writeAsBytesSync([4, 3, 2, 1]);
    final externalThumbnail = File(
      '${root.path}${Platform.pathSeparator}external.png',
    )..writeAsBytesSync([9, 9]);
    final userDirectory = Directory(
      '${root.path}${Platform.pathSeparator}rims_attachments${Platform.pathSeparator}user_NDI',
    );
    await userDirectory.create(recursive: true);
    final manifest = File(
      '${userDirectory.path}${Platform.pathSeparator}manifest.json',
    );
    Future<void> writeMaliciousManifest() => manifest.writeAsString(
      jsonEncode({
        'version': 1,
        'items': [
          {
            'requestId': 'outside-request',
            'businessType': 'document_draft',
            'businessId': 1,
            'localDraftId': 'draft-source',
            'stagedPath': externalFile.path,
            'originalName': 'outside.pdf',
            'mimeType': 'application/pdf',
            'fileSize': 4,
            'thumbnailPath': externalThumbnail.path,
            'createdAt': DateTime.utc(2020).toIso8601String(),
          },
        ],
      }),
      flush: true,
    );
    final staging = store(idFactory: () => 'safe-id');

    await writeMaliciousManifest();
    final recovered = await staging.recoverForUser('42');
    expect(
      recovered.when(success: (items) => items, failure: (_) => null),
      isEmpty,
    );
    expect(externalFile.existsSync(), isTrue);
    expect(externalThumbnail.existsSync(), isTrue);

    await writeMaliciousManifest();
    expect(
      (await staging.duplicateDraftAttachments(
        userId: '42',
        sourceDraftId: 'draft-source',
        targetDraftId: 'draft-copy',
        requestIds: const ['outside-request'],
      )).isFailure,
      isTrue,
    );
    expect(externalFile.existsSync(), isTrue);

    await writeMaliciousManifest();
    await staging.removeStagedAttachments(
      userId: '42',
      requestIds: const ['outside-request'],
    );
    expect(externalFile.existsSync(), isTrue);
    expect(externalThumbnail.existsSync(), isTrue);

    await writeMaliciousManifest();
    await staging.cleanupStale(userId: '42', maxAge: const Duration(days: 1));
    expect(externalFile.existsSync(), isTrue);
    expect(externalThumbnail.existsSync(), isTrue);
  });

  test('concurrent stages serialize manifest read modify write', () async {
    var nextId = 0;
    var manifestReads = 0;
    final firstRead = Completer<void>();
    final releaseFirstRead = Completer<void>();
    final staging = store(
      idFactory: () => 'id-${nextId++}',
      onManifestRead: (_) async {
        manifestReads += 1;
        if (manifestReads == 1) {
          firstRead.complete();
          await releaseFirstRead.future;
        }
      },
    );

    final first = staging.stage(
      userId: '42',
      binding: AttachmentBinding.documentDraft('draft'),
      selection: selection(name: 'first.jpg'),
      existingCount: 0,
    );
    await firstRead.future;
    final second = staging.stage(
      userId: '42',
      binding: AttachmentBinding.documentDraft('draft'),
      selection: selection(name: 'second.jpg'),
      existingCount: 0,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    releaseFirstRead.complete();

    expect((await first).isSuccess, isTrue);
    expect((await second).isSuccess, isTrue);
    final recovered = await store().recoverForUser('42');
    recovered.when(
      success: (items) => expect(items, hasLength(2)),
      failure: (failure) => fail(failure.message),
    );
  });

  test(
    'duplicates draft files with new ids and independent lifecycle',
    () async {
      final ids = [
        'source-request',
        'manifest-source',
        'copy-request',
        'manifest-copy',
        'manifest-remove',
      ].iterator;
      final staging = store(
        idFactory: () {
          ids.moveNext();
          return ids.current;
        },
      );
      final sourceResult = await staging.stage(
        userId: '42',
        binding: AttachmentBinding.documentDraft('draft-source'),
        selection: selection(),
        existingCount: 0,
      );
      final sourceItem = sourceResult.when(
        success: (item) => item,
        failure: (failure) => throw TestFailure(failure.message),
      );

      final duplicated = await staging.duplicateDraftAttachments(
        userId: '42',
        sourceDraftId: 'draft-source',
        targetDraftId: 'draft-copy',
        requestIds: [sourceItem.pending.requestId],
      );

      final copyItem = duplicated.when(
        success: (items) => items.single,
        failure: (failure) => throw TestFailure(failure.message),
      );
      expect(copyItem.pending.requestId, isNot(sourceItem.pending.requestId));
      expect(copyItem.pending.binding.localDraftId, 'draft-copy');
      expect(copyItem.pending.stagedPath, isNot(sourceItem.pending.stagedPath));
      final reopened = await store().recoverForUser('42');
      final reopenedCopy = reopened.when(
        success: (items) => items.singleWhere(
          (item) => item.pending.binding.localDraftId == 'draft-copy',
        ),
        failure: (failure) => throw TestFailure(failure.message),
      );
      expect(reopenedCopy.pending.requestId, copyItem.pending.requestId);
      await File(reopenedCopy.pending.stagedPath).writeAsBytes([8, 8, 8]);
      expect(File(sourceItem.pending.stagedPath).readAsBytesSync(), [
        1,
        2,
        3,
        4,
      ]);

      await staging.remove('42', copyItem.pending.requestId);
      final recovered = await staging.recoverForUser('42');
      recovered.when(
        success: (items) {
          expect(items.map((item) => item.pending.requestId), [
            sourceItem.pending.requestId,
          ]);
          expect(File(sourceItem.pending.stagedPath).existsSync(), isTrue);
        },
        failure: (failure) => fail(failure.message),
      );
    },
  );

  test(
    'failed draft duplication leaves no partial files or manifest rows',
    () async {
      final sourceIds = ['source-request', 'manifest-source'].iterator;
      final sourceStore = store(
        idFactory: () {
          sourceIds.moveNext();
          return sourceIds.current;
        },
      );
      await sourceStore.stage(
        userId: '42',
        binding: AttachmentBinding.documentDraft('draft-source'),
        selection: selection(),
        existingCount: 0,
      );
      final failingStore = store(
        idFactory: () => 'failed-copy',
        copyFile: (_, destination) async {
          await File(destination).writeAsBytes([1, 2]);
          throw const FileSystemException('copy failed');
        },
      );

      final result = await failingStore.duplicateDraftAttachments(
        userId: '42',
        sourceDraftId: 'draft-source',
        targetDraftId: 'draft-copy',
        requestIds: const ['source-request'],
      );

      expect(result.isFailure, isTrue);
      expect(
        root
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.contains('failed-copy')),
        isEmpty,
      );
      final recovered = await sourceStore.recoverForUser('42');
      recovered.when(
        success: (items) {
          expect(items.map((item) => item.pending.requestId), [
            'source-request',
          ]);
          expect(
            items.where(
              (item) => item.pending.binding.localDraftId == 'draft-copy',
            ),
            isEmpty,
          );
        },
        failure: (failure) => fail(failure.message),
      );
    },
  );

  test(
    'failed cleanup persists intent and a rebuilt store removes orphans',
    () async {
      final ids = [
        'source-request',
        'manifest-source',
        'copy-request',
        'manifest-copy',
        'manifest-recovery',
      ].iterator;
      var failCleanup = true;
      final staging = store(
        idFactory: () {
          ids.moveNext();
          return ids.current;
        },
        deleteFile: (file) async {
          if (failCleanup && file.path.contains('copy-request')) {
            failCleanup = false;
            throw const FileSystemException('injected cleanup failure');
          }
          if (await file.exists()) await file.delete();
        },
      );
      final sourceResult = await staging.stage(
        userId: '42',
        binding: AttachmentBinding.documentDraft('draft-source'),
        selection: selection(),
        existingCount: 0,
      );
      final sourceItem = sourceResult.when(
        success: (item) => item,
        failure: (failure) => throw TestFailure(failure.message),
      );
      final duplicateResult = await staging.duplicateDraftAttachments(
        userId: '42',
        sourceDraftId: 'draft-source',
        targetDraftId: 'draft-copy',
        requestIds: [sourceItem.pending.requestId],
      );
      final copyItem = duplicateResult.when(
        success: (items) => items.single,
        failure: (failure) => throw TestFailure(failure.message),
      );

      final removal = await staging.removeStagedAttachments(
        userId: '42',
        requestIds: [copyItem.pending.requestId],
      );

      expect(removal.isFailure, isTrue);
      expect(
        root
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('pending_cleanup.json')),
        hasLength(1),
      );
      expect(File(copyItem.pending.stagedPath).existsSync(), isTrue);

      final recovered = await store().recoverForUser('42');
      recovered.when(
        success: (items) {
          expect(items.map((item) => item.pending.requestId), [
            sourceItem.pending.requestId,
          ]);
        },
        failure: (failure) => fail(failure.message),
      );
      expect(File(copyItem.pending.stagedPath).existsSync(), isFalse);
      expect(
        root
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('pending_cleanup.json')),
        isEmpty,
      );
    },
  );

  test(
    'manifest cleanup failure is retried without temporary orphans',
    () async {
      final ids = [
        'source-request',
        'manifest-source',
        'copy-request',
        'manifest-copy',
        'manifest-cleanup',
      ].iterator;
      var manifestCommits = 0;
      final staging = store(
        idFactory: () {
          ids.moveNext();
          return ids.current;
        },
        commitManifest: (temporary, target) async {
          manifestCommits += 1;
          if (manifestCommits == 3) {
            throw const FileSystemException('injected manifest failure');
          }
          await temporary.rename(target.path);
        },
      );
      final source =
          (await staging.stage(
            userId: '42',
            binding: AttachmentBinding.documentDraft('draft-source'),
            selection: selection(),
            existingCount: 0,
          )).when(
            success: (item) => item,
            failure: (failure) => throw TestFailure(failure.message),
          );
      final copy =
          (await staging.duplicateDraftAttachments(
            userId: '42',
            sourceDraftId: 'draft-source',
            targetDraftId: 'draft-copy',
            requestIds: [source.pending.requestId],
          )).when(
            success: (items) => items.single,
            failure: (failure) => throw TestFailure(failure.message),
          );

      final removal = await staging.removeStagedAttachments(
        userId: '42',
        requestIds: [copy.pending.requestId],
      );

      expect(removal.isFailure, isTrue);
      expect(
        root
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('pending_cleanup.json')),
        hasLength(1),
      );
      expect(
        root
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.tmp')),
        isEmpty,
      );

      final recovered = await store().recoverForUser('42');
      recovered.when(
        success: (items) => expect(
          items.map((item) => item.pending.requestId),
          [source.pending.requestId],
        ),
        failure: (failure) => fail(failure.message),
      );
      expect(File(copy.pending.stagedPath).existsSync(), isFalse);
      expect(
        root
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('pending_cleanup.json')),
        isEmpty,
      );
    },
  );

  test(
    'rejects unsupported type, oversize source, and exhausted count',
    () async {
      final staging = store();

      for (final request in [
        () => staging.stage(
          userId: '42',
          binding: AttachmentBinding.document(9),
          selection: selection(
            name: 'script.exe',
            mime: 'application/octet-stream',
          ),
          existingCount: 0,
        ),
        () => staging.stage(
          userId: '42',
          binding: AttachmentBinding.document(9),
          selection: selection(name: 'disguised.jpg', mime: 'text/html'),
          existingCount: 0,
        ),
        () => staging.stage(
          userId: '42',
          binding: AttachmentBinding.document(9),
          selection: selection(size: 10 * 1024 * 1024 + 1),
          existingCount: 0,
        ),
        () => staging.stage(
          userId: '42',
          binding: AttachmentBinding.document(9),
          selection: selection(),
          existingCount: 9,
        ),
      ]) {
        expect((await request()).isFailure, isTrue);
      }
    },
  );

  test(
    'request-id collision never overwrites an existing staged file',
    () async {
      final staging = store();
      final first = await staging.stage(
        userId: '42',
        binding: AttachmentBinding.document(9),
        selection: selection(),
        existingCount: 0,
      );
      final originalPath = first.when(
        success: (item) => item.pending.stagedPath,
        failure: (failure) => throw StateError(failure.message),
      );

      await source.writeAsBytes([7, 7, 7, 7]);
      final collision = await staging.stage(
        userId: '42',
        binding: AttachmentBinding.document(9),
        selection: selection(),
        existingCount: 1,
      );

      expect(collision.isFailure, isTrue);
      expect(File(originalPath).readAsBytesSync(), [1, 2, 3, 4]);
    },
  );

  test(
    'copy/no-space failure leaves no manifest entry or partial file',
    () async {
      final staging = store(
        copyFile: (_, destination) async =>
            throw const FileSystemException('No space left'),
      );

      final result = await staging.stage(
        userId: '42',
        binding: AttachmentBinding.document(9),
        selection: selection(),
        existingCount: 0,
      );

      expect(result.isFailure, isTrue);
      final recovered = await staging.recoverForUser('42');
      recovered.when(
        success: (items) => expect(items, isEmpty),
        failure: (failure) => fail(failure.message),
      );
    },
  );

  test('stale cleanup and logout clear only files owned by the user', () async {
    final staging = store(now: DateTime.utc(2026, 7, 1));
    await staging.stage(
      userId: '42',
      binding: AttachmentBinding.document(9),
      selection: selection(),
      existingCount: 0,
    );
    final other = store(now: DateTime.utc(2026, 7, 1));
    await other.stage(
      userId: '99',
      binding: AttachmentBinding.document(9),
      selection: selection(),
      existingCount: 0,
    );
    final oldDownload = await other.saveDownload(
      userId: '99',
      originalName: 'old.pdf',
      bytes: Uint8List.fromList([1]),
    );
    final oldDownloadPath = oldDownload.when(
      success: (path) => path,
      failure: (failure) => throw StateError(failure.message),
    );
    await File(oldDownloadPath).setLastModified(DateTime.utc(2026, 7, 1));

    final cleaner = store(now: DateTime.utc(2026, 7, 13));
    await cleaner.cleanupStale(
      userId: '42',
      maxAge: const Duration(days: 7),
      protectedRequestIds: const {'request-1'},
    );
    expect(File(oldDownloadPath).existsSync(), isTrue);
    expect((await cleaner.recoverForUser('42')).successData, hasLength(1));
    expect((await cleaner.recoverForUser('99')).successData, hasLength(1));

    await cleaner.cleanupStale(userId: '42', maxAge: const Duration(days: 7));
    expect((await cleaner.recoverForUser('42')).successData, isEmpty);
    expect((await cleaner.recoverForUser('99')).successData, hasLength(1));

    await cleaner.saveDownload(
      userId: '99',
      originalName: 'receipt.pdf',
      bytes: Uint8List.fromList([4, 5, 6]),
    );
    await cleaner.clearForUser('42');
    expect((await cleaner.recoverForUser('99')).isSuccess, isTrue);
    expect(await cleaner.userDirectoryExists('99'), isTrue);
  });

  test(
    'process recreation keeps a seven-day-old conflict staging reference',
    () async {
      final original = store(now: DateTime.utc(2026, 7, 1));
      await original.stage(
        userId: '42',
        binding: AttachmentBinding.documentDraft('draft-1'),
        selection: selection(),
        existingCount: 0,
      );
      final conflict = OutboxOperation(
        operationId: 'upload-request-1',
        idempotencyKey: 'request-1',
        accountId: '42',
        warehouseId: 11,
        kind: OutboxOperationKind.attachmentUpload,
        payload: const {'version': 1, 'requestId': 'request-1'},
        state: OutboxState.conflict,
        createdAt: DateTime.utc(2026, 7, 1),
      );

      final rebuilt = store(now: DateTime.utc(2026, 7, 13));
      await rebuilt.cleanupStale(
        userId: '42',
        maxAge: const Duration(days: 7),
        protectedRequestIds: AttachmentStagingProtection.requestIdsFor([
          conflict,
        ]),
      );
      expect((await rebuilt.recoverForUser('42')).successData, hasLength(1));

      await rebuilt.cleanupStale(
        userId: '42',
        maxAge: const Duration(days: 7),
        protectedRequestIds: AttachmentStagingProtection.requestIdsFor(
          const [],
        ),
      );
      expect((await rebuilt.recoverForUser('42')).successData, isEmpty);
    },
  );

  test(
    'thumbnail keeps decoded orientation and bounds the longest side',
    () async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 1024, 256),
        ui.Paint()..color = const ui.Color(0xFF336699),
      );
      final image = await recorder.endRecording().toImage(1024, 256);
      final sourceBytes = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      image.dispose();
      final imagePath = '${root.path}${Platform.pathSeparator}wide.png';
      final thumbnailPath = '${root.path}${Platform.pathSeparator}thumb.png';
      await File(imagePath).writeAsBytes(sourceBytes!.buffer.asUint8List());

      await buildBoundedThumbnail(imagePath, thumbnailPath);
      final buffer = await ui.ImmutableBuffer.fromFilePath(thumbnailPath);
      final codec = await ui.instantiateImageCodecFromBuffer(buffer);
      final frame = await codec.getNextFrame();

      expect(frame.image.width, 512);
      expect(frame.image.height, 128);
      frame.image.dispose();
      codec.dispose();
    },
  );

  test('thumbnail honors EXIF rotation from a camera JPEG', () async {
    final imagePath = '${root.path}${Platform.pathSeparator}rotated.jpg';
    final thumbnailPath = '${root.path}${Platform.pathSeparator}rotated.png';
    await File(imagePath).writeAsBytes(base64Decode(_orientationSixJpeg));

    await buildBoundedThumbnail(imagePath, thumbnailPath);
    final buffer = await ui.ImmutableBuffer.fromFilePath(thumbnailPath);
    final codec = await ui.instantiateImageCodecFromBuffer(buffer);
    final frame = await codec.getNextFrame();

    expect(frame.image.width, 40);
    expect(frame.image.height, 80);
    frame.image.dispose();
    codec.dispose();
  });
}

extension<T> on Result<T> {
  T get successData => (this as Success<T>).data;

  Failure? get failureOrNull => switch (this) {
    FailureResult<T>(:final failure) => failure,
    _ => null,
  };
}

const _orientationSixJpeg =
    '/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAYAAAAAAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAoAFADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDzqiiivjj+kQooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKAP//Z';
