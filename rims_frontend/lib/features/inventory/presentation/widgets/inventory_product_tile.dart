import 'package:flutter/material.dart';

import '../../../../core/resources/app_images.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_status_chip.dart';
import '../../domain/entities/inventory_item.dart';

final class InventoryProductTile extends StatelessWidget {
  const InventoryProductTile({required this.product, super.key});

  final InventoryItem product;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ColoredBox(
              color: AppColors.primaryLight,
              child: _InventoryProductImage(imageUrl: product.imageUrl),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        product.productName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.titleMedium,
                      ),
                    ),
                    const SizedBox(width: 8),
                    RimsStatusChip(
                      label: product.statusLabel,
                      kind: _statusKind(product.statusLabel),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  product.sku,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodySmall,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _InventoryCount(
                      label: '可用',
                      value: product.availableQuantity,
                    ),
                    const SizedBox(width: 16),
                    _InventoryCount(label: '库存', value: product.stockQuantity),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  RimsStatusKind _statusKind(String status) {
    return switch (status) {
      '标准' => RimsStatusKind.success,
      '低库存' => RimsStatusKind.warning,
      '非标' => RimsStatusKind.info,
      _ => RimsStatusKind.pending,
    };
  }
}

final class _InventoryProductImage extends StatelessWidget {
  const _InventoryProductImage({required this.imageUrl});

  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    if (imageUrl.startsWith('http://') || imageUrl.startsWith('https://')) {
      return Image.network(
        imageUrl,
        width: 58,
        height: 58,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => const _FallbackImage(),
      );
    }

    return const _FallbackImage();
  }
}

final class _FallbackImage extends StatelessWidget {
  const _FallbackImage();

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      AppImages.productWaterBottle,
      width: 58,
      height: 58,
      fit: BoxFit.cover,
    );
  }
}

final class _InventoryCount extends StatelessWidget {
  const _InventoryCount({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Flexible(
      child: RichText(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: AppTextStyles.bodySmall,
          children: [
            TextSpan(text: '$label '),
            TextSpan(
              text: '$value',
              style: AppTextStyles.bodyMedium.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
