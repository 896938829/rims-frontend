import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/attachments/data/services/android_attachment_picker.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_picker.dart';

void main() {
  test(
    'camera and gallery use bounded privacy-preserving image options',
    () async {
      final images = _FakeImageGateway(
        result: const SelectedAttachmentSource(
          path: '/tmp/photo.jpg',
          originalName: 'photo.jpg',
          mimeType: 'image/jpeg',
          fileSize: 12,
        ),
      );
      final picker = AndroidAttachmentPicker(
        imageGateway: images,
        fileGateway: _FakeFileGateway(),
      );

      await picker.pick(AttachmentPickSource.camera);
      expect(images.lastSource, AttachmentPickSource.camera);
      expect(images.maxWidth, 1920);
      expect(images.maxHeight, 1920);
      expect(images.quality, 82);
      expect(images.requestFullMetadata, isFalse);

      await picker.pick(AttachmentPickSource.gallery);
      expect(images.lastSource, AttachmentPickSource.gallery);
    },
  );

  test('file selection uses the accepted extension allow-list', () async {
    final files = _FakeFileGateway(
      result: const SelectedAttachmentSource(
        path: '/tmp/report.pdf',
        originalName: 'report.pdf',
        mimeType: 'application/pdf',
        fileSize: 12,
      ),
    );
    final picker = AndroidAttachmentPicker(
      imageGateway: _FakeImageGateway(),
      fileGateway: files,
    );

    final result = await picker.pick(AttachmentPickSource.file);

    expect(result.isSuccess, isTrue);
    expect(files.allowedExtensions, [
      'jpg',
      'jpeg',
      'png',
      'gif',
      'pdf',
      'csv',
      'xlsx',
    ]);
  });

  test('picker cancellation is a neutral successful null result', () async {
    final picker = AndroidAttachmentPicker(
      imageGateway: _FakeImageGateway(),
      fileGateway: _FakeFileGateway(),
    );

    final result = await picker.pick(AttachmentPickSource.camera);

    result.when(
      success: (selection) => expect(selection, isNull),
      failure: (failure) => fail(failure.message),
    );
  });

  test(
    'platform permission denial becomes a device permission failure',
    () async {
      final picker = AndroidAttachmentPicker(
        imageGateway: _FakeImageGateway(
          error: PlatformException(code: 'camera_access_denied'),
        ),
        fileGateway: _FakeFileGateway(),
      );

      final result = await picker.pick(AttachmentPickSource.camera);

      result.when(
        success: (_) => fail('expected permission failure'),
        failure: (failure) =>
            expect(failure.runtimeType.toString(), 'DevicePermissionFailure'),
      );
    },
  );

  test('lost picker data is recovered and retained until consumed', () async {
    final images = _FakeImageGateway(
      recovered: const [
        SelectedAttachmentSource(
          path: '/tmp/recovered.jpg',
          originalName: 'recovered.jpg',
          mimeType: 'image/jpeg',
          fileSize: 24,
        ),
      ],
    );
    final picker = AndroidAttachmentPicker(
      imageGateway: images,
      fileGateway: _FakeFileGateway(),
    );

    expect((await picker.recoverLostData()).isSuccess, isTrue);
    expect(picker.takeRecovered().single.originalName, 'recovered.jpg');
    expect(picker.takeRecovered(), isEmpty);
  });
}

final class _FakeImageGateway implements ImageSelectionGateway {
  _FakeImageGateway({this.result, this.recovered = const [], this.error});

  final SelectedAttachmentSource? result;
  final List<SelectedAttachmentSource> recovered;
  final Object? error;
  AttachmentPickSource? lastSource;
  double? maxWidth;
  double? maxHeight;
  int? quality;
  bool? requestFullMetadata;

  @override
  Future<SelectedAttachmentSource?> pick({
    required AttachmentPickSource source,
    required double maxWidth,
    required double maxHeight,
    required int quality,
    required bool requestFullMetadata,
  }) async {
    if (error != null) throw error!;
    lastSource = source;
    this.maxWidth = maxWidth;
    this.maxHeight = maxHeight;
    this.quality = quality;
    this.requestFullMetadata = requestFullMetadata;
    return result;
  }

  @override
  Future<List<SelectedAttachmentSource>> recoverLost() async => recovered;
}

final class _FakeFileGateway implements FileSelectionGateway {
  _FakeFileGateway({this.result});

  final SelectedAttachmentSource? result;
  List<String>? allowedExtensions;

  @override
  Future<SelectedAttachmentSource?> pick({
    required List<String> allowedExtensions,
  }) async {
    this.allowedExtensions = allowedExtensions;
    return result;
  }
}
