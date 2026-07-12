import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/attachments/data/services/attachment_share_service.dart';

void main() {
  test(
    'shares only an existing local download with name and MIME type',
    () async {
      String? path;
      final service = PlatformAttachmentShareService(
        fileExists: (_) async => true,
        shareFile: (sharedPath, name, mimeType) async {
          path = sharedPath;
          expect(name, 'receipt.pdf');
          expect(mimeType, 'application/pdf');
        },
      );

      final result = await service.share(
        path: '/support/receipt.pdf',
        originalName: 'receipt.pdf',
        mimeType: 'application/pdf',
      );

      expect(result.isSuccess, isTrue);
      expect(path, '/support/receipt.pdf');
    },
  );

  test('missing local download returns a storage failure', () async {
    final service = PlatformAttachmentShareService(
      fileExists: (_) async => false,
      shareFile: (_, name, mimeType) async {},
    );

    final result = await service.share(
      path: '/missing.pdf',
      originalName: 'missing.pdf',
      mimeType: 'application/pdf',
    );

    expect(result.isFailure, isTrue);
  });
}
