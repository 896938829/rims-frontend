import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/services/attachment_picker.dart';

const List<String> kAcceptedAttachmentExtensions = [
  'jpg',
  'jpeg',
  'png',
  'gif',
  'pdf',
  'csv',
  'xlsx',
];

abstract interface class ImageSelectionGateway {
  Future<SelectedAttachmentSource?> pick({
    required AttachmentPickSource source,
    required double maxWidth,
    required double maxHeight,
    required int quality,
    required bool requestFullMetadata,
  });

  Future<List<SelectedAttachmentSource>> recoverLost();
}

abstract interface class FileSelectionGateway {
  Future<SelectedAttachmentSource?> pick({
    required List<String> allowedExtensions,
  });
}

final class AndroidAttachmentPicker implements AttachmentPicker {
  AndroidAttachmentPicker({
    ImageSelectionGateway? imageGateway,
    FileSelectionGateway? fileGateway,
  }) : _imageGateway = imageGateway ?? PluginImageSelectionGateway(),
       _fileGateway = fileGateway ?? const PluginFileSelectionGateway();

  final ImageSelectionGateway _imageGateway;
  final FileSelectionGateway _fileGateway;
  final List<SelectedAttachmentSource> _recovered = [];

  @override
  Future<Result<SelectedAttachmentSource?>> pick(
    AttachmentPickSource source,
  ) async {
    try {
      final selection = source == AttachmentPickSource.file
          ? await _fileGateway.pick(
              allowedExtensions: kAcceptedAttachmentExtensions,
            )
          : await _imageGateway.pick(
              source: source,
              maxWidth: 1920,
              maxHeight: 1920,
              quality: 82,
              requestFullMetadata: false,
            );
      return Success(selection);
    } on PlatformException catch (error) {
      if (_isPermissionError(error)) {
        return FailureResult(
          DevicePermissionFailure(
            message: 'Attachment source permission denied.',
            cause: error,
          ),
        );
      }
      return FailureResult(
        AttachmentFailure(
          message: error.message ?? 'Unable to select attachment.',
          cause: error,
        ),
      );
    } catch (error) {
      return FailureResult(
        AttachmentFailure(
          message: 'Unable to select attachment.',
          cause: error,
        ),
      );
    }
  }

  @override
  Future<Result<List<SelectedAttachmentSource>>> recoverLostData() async {
    try {
      final recovered = await _imageGateway.recoverLost();
      _recovered.addAll(recovered);
      return Success(List.unmodifiable(recovered));
    } on PlatformException catch (error) {
      return FailureResult(
        AttachmentFailure(
          message: error.message ?? 'Unable to recover selected images.',
          cause: error,
        ),
      );
    } catch (error) {
      return FailureResult(
        AttachmentFailure(
          message: 'Unable to recover selected images.',
          cause: error,
        ),
      );
    }
  }

  @override
  List<SelectedAttachmentSource> takeRecovered() {
    final result = List<SelectedAttachmentSource>.unmodifiable(_recovered);
    _recovered.clear();
    return result;
  }

  bool _isPermissionError(PlatformException error) {
    final code = error.code.toLowerCase();
    return code.contains('denied') ||
        code.contains('permission') ||
        code.contains('access');
  }
}

final class PluginImageSelectionGateway implements ImageSelectionGateway {
  PluginImageSelectionGateway([ImagePicker? picker])
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<SelectedAttachmentSource?> pick({
    required AttachmentPickSource source,
    required double maxWidth,
    required double maxHeight,
    required int quality,
    required bool requestFullMetadata,
  }) async {
    final file = await _picker.pickImage(
      source: source == AttachmentPickSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      imageQuality: quality,
      requestFullMetadata: requestFullMetadata,
    );
    return file == null ? null : _fromXFile(file);
  }

  @override
  Future<List<SelectedAttachmentSource>> recoverLost() async {
    final response = await _picker.retrieveLostData();
    if (response.isEmpty) return const [];
    if (response.exception != null) throw response.exception!;
    final files = response.files ?? [if (response.file != null) response.file!];
    final recovered = <SelectedAttachmentSource>[];
    for (final file in files) {
      recovered.add(await _fromXFile(file));
    }
    return recovered;
  }

  Future<SelectedAttachmentSource> _fromXFile(XFile file) async {
    return SelectedAttachmentSource(
      path: file.path,
      originalName: file.name,
      mimeType: file.mimeType ?? _mimeFromName(file.name),
      fileSize: await file.length(),
    );
  }
}

final class PluginFileSelectionGateway implements FileSelectionGateway {
  const PluginFileSelectionGateway();

  @override
  Future<SelectedAttachmentSource?> pick({
    required List<String> allowedExtensions,
  }) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      allowMultiple: false,
      withData: false,
      withReadStream: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    final path = file.path;
    if (path == null || path.isEmpty) {
      throw PlatformException(
        code: 'attachment_path_unavailable',
        message: 'Selected file has no readable local path.',
      );
    }
    return SelectedAttachmentSource(
      path: path,
      originalName: file.name,
      mimeType: _mimeFromName(file.name),
      fileSize: file.size,
    );
  }
}

String _mimeFromName(String name) {
  final extension = name.toLowerCase().split('.').last;
  return switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'pdf' => 'application/pdf',
    'csv' => 'text/csv',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    _ => 'application/octet-stream',
  };
}
