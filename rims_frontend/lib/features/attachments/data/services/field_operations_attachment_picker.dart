import 'dart:convert';
import 'dart:io';

import '../../../../core/result/result.dart';
import '../../domain/services/attachment_picker.dart';

final class FieldOperationsAttachmentPicker implements AttachmentPicker {
  FieldOperationsAttachmentPicker({
    required this.rootDirectory,
    required this.providerToken,
  });

  final Future<Directory> Function() rootDirectory;
  final String providerToken;
  Directory? _ownedDirectory;

  @override
  Future<Result<SelectedAttachmentSource?>> pick(
    AttachmentPickSource source,
  ) async {
    final root = await rootDirectory();
    final owned = Directory(
      '${root.path}${Platform.pathSeparator}.rims-e2e-provider',
    );
    await owned.create(recursive: true);
    _ownedDirectory = owned;
    final target = File(
      '${owned.path}${Platform.pathSeparator}m10-field-operations.png',
    );
    final provider = File(providerToken);
    if (providerToken != 'provider-file' && await provider.exists()) {
      await provider.copy(target.path);
    } else {
      final png = base64Decode(_onePixelPng);
      final sink = target.openWrite();
      sink.add(png);
      sink.add(List<int>.filled(_providerSize - png.length, 0));
      await sink.close();
    }
    return Success(
      SelectedAttachmentSource(
        path: target.path,
        originalName: 'm10-field-operations.png',
        mimeType: 'image/png',
        fileSize: await target.length(),
      ),
    );
  }

  @override
  Future<Result<List<SelectedAttachmentSource>>> recoverLostData() async =>
      const Success([]);

  @override
  List<SelectedAttachmentSource> takeRecovered() => const [];

  Future<void> cleanup() async {
    final owned = _ownedDirectory;
    if (owned != null && await owned.exists()) {
      await owned.delete(recursive: true);
    }
    _ownedDirectory = null;
  }
}

const String _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
const int _providerSize = 5 * 1024 * 1024;
