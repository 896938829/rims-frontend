import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

final class AttachmentPreview extends StatelessWidget {
  const AttachmentPreview({
    required this.mimeType,
    this.localPath,
    this.size = 48,
    super.key,
  });

  final String mimeType;
  final String? localPath;
  final double size;

  @override
  Widget build(BuildContext context) {
    final path = localPath;
    final isImage = mimeType.startsWith('image/');
    return SizedBox.square(
      dimension: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: AppColors.border),
          ),
          child: isImage && path != null
              ? Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  errorBuilder: (_, error, stackTrace) => const Icon(
                    Icons.broken_image_outlined,
                    color: AppColors.textSecondary,
                  ),
                )
              : Icon(_iconForMime(mimeType), color: AppColors.textSecondary),
        ),
      ),
    );
  }

  IconData _iconForMime(String mimeType) {
    if (mimeType == 'application/pdf') return Icons.picture_as_pdf_outlined;
    if (mimeType.contains('spreadsheet') || mimeType.contains('csv')) {
      return Icons.table_chart_outlined;
    }
    if (mimeType.startsWith('image/')) return Icons.image_outlined;
    return Icons.insert_drive_file_outlined;
  }
}
