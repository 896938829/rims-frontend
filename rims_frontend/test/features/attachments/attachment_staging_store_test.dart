import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/attachments/data/services/file_attachment_staging_store.dart';
import 'package:rims_frontend/features/attachments/domain/entities/attachment.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_picker.dart';

void main() {
  late Directory root;
  late File source;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rims_stage_test_');
    source = File('${root.path}${Platform.pathSeparator}source.jpg');
    await source.writeAsBytes(Uint8List.fromList([1, 2, 3, 4]));
  });

  tearDown(() => root.delete(recursive: true));

  FileAttachmentStagingStore store({FileCopier? copyFile, DateTime? now}) {
    return FileAttachmentStagingStore(
      rootDirectory: () async => root,
      idFactory: () => 'request-1',
      clock: () => now ?? DateTime.utc(2026, 7, 13),
      copyFile: copyFile,
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
    await cleaner.cleanupStale(maxAge: const Duration(days: 7));
    expect(File(oldDownloadPath).existsSync(), isFalse);
    for (final userId in ['42', '99']) {
      (await cleaner.recoverForUser(userId)).when(
        success: (items) => expect(items, isEmpty),
        failure: (failure) => fail(failure.message),
      );
    }

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

const _orientationSixJpeg =
    '/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAYAAAAAAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAoAFADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDzqiiivjj+kQooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKAP//Z';
