import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/attachments/data/services/field_operations_attachment_picker.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_picker.dart';

void main() {
  test(
    'deterministic picker creates and cleans an owned local image',
    () async {
      final root = await Directory.systemTemp.createTemp('rims-field-picker-');
      addTearDown(() => root.delete(recursive: true));
      final picker = FieldOperationsAttachmentPicker(
        rootDirectory: () async => root,
        providerToken: 'provider-file',
      );

      final result = await picker.pick(AttachmentPickSource.camera);
      final selection = result.when(
        success: (value) => value,
        failure: (failure) => throw failure,
      );

      expect(selection, isNotNull);
      expect(selection!.originalName, 'm10-field-operations.png');
      expect(selection.mimeType, 'image/png');
      expect(selection.fileSize, 5 * 1024 * 1024);
      expect(await File(selection.path).exists(), isTrue);
      expect(await picker.recoverLostData(), isA<Object>());

      await picker.cleanup();
      expect(await File(selection.path).exists(), isFalse);
    },
  );
}
