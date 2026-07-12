import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/attachments/data/models/attachment_models.dart';

void main() {
  const json = <String, Object?>{
    'id': 7,
    'businessType': 'doc_attachment',
    'businessId': 42,
    'fileUrl': '/api/v1/files/7/download',
    'originalName': 'receipt.pdf',
    'fileSize': 1024,
    'mimeType': 'application/pdf',
    'fileHash': 'abc123',
    'isPublic': false,
    'createdBy': 3,
    'uploadedAt': '2026-07-13T08:30:00Z',
    'position': 1,
  };

  test('parses a strict attachment and resolves a same-origin path', () {
    final model = AttachmentModel.fromJson(json);
    final attachment = model.toEntity(
      Uri.parse('http://localhost:8080/api/v1'),
    );

    expect(attachment.id, 7);
    expect(attachment.binding.businessType, 'doc_attachment');
    expect(attachment.binding.businessId, 42);
    expect(
      attachment.downloadUri,
      Uri.parse('http://localhost:8080/api/v1/files/7/download'),
    );
    expect(attachment.position, 1);
  });

  test('rejects malformed required fields', () {
    for (final entry in <String, Object?>{
      'id': 0,
      'businessId': null,
      'fileSize': -1,
      'uploadedAt': 'not-a-date',
      'position': -1,
    }.entries) {
      expect(
        () => AttachmentModel.fromJson({...json, entry.key: entry.value}),
        throwsFormatException,
        reason: entry.key,
      );
    }
  });

  test(
    'rejects external, protocol-relative, query, and fragment file URLs',
    () {
      for (final value in <String>[
        'https://evil.example/file',
        '//evil.example/file',
        '/api/v1/files/7/download?token=secret',
        '/api/v1/files/7/download#fragment',
      ]) {
        final model = AttachmentModel.fromJson({...json, 'fileUrl': value});
        expect(
          () => model.toEntity(Uri.parse('http://localhost:8080/api/v1')),
          throwsFormatException,
          reason: value,
        );
      }
    },
  );
}
