import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_status_chip.dart';
import '../../domain/entities/admin_product.dart';
import '../../domain/repositories/admin_repository.dart';
import '../view_models/admin_products_view_model.dart';

final class AdminProductsPanel extends StatefulWidget {
  const AdminProductsPanel({
    this.repository,
    this.viewModel,
    this.eventBus,
    super.key,
  });

  final AdminRepository? repository;
  final AdminProductsViewModel? viewModel;
  final AppEventBus? eventBus;

  @override
  State<AdminProductsPanel> createState() => _AdminProductsPanelState();
}

final class _AdminProductsPanelState extends State<AdminProductsPanel> {
  late final AdminProductsViewModel viewModel;
  late final bool _ownsViewModel;

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    viewModel =
        widget.viewModel ??
        AdminProductsViewModel(
          repository: widget.repository,
          eventBus: widget.eventBus,
        );

    if (_ownsViewModel) {
      unawaited(viewModel.load());
    }
  }

  @override
  void dispose() {
    if (_ownsViewModel) {
      viewModel.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: viewModel,
      builder: (context, _) {
        return RimsCard(
          key: const Key('profile-admin-products-panel'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('商品管理', style: AppTextStyles.titleMedium),
                  ),
                  IconButton(
                    key: const Key('admin-create-product-button'),
                    tooltip: '创建商品',
                    onPressed: viewModel.isCreatingProduct
                        ? null
                        : () => _showCreateProductDialog(context),
                    icon: const Icon(Icons.add_box_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('admin-products-search-field'),
                onChanged: (value) => unawaited(viewModel.updateQuery(value)),
                style: AppTextStyles.bodyMedium,
                decoration: const InputDecoration(
                  hintText: '搜索商品编码、名称或条码',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              if (viewModel.isLoading && viewModel.products.isEmpty)
                Text(
                  '正在加载商品...',
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.textSecondary,
                  ),
                )
              else if (viewModel.errorMessage != null)
                Text(
                  viewModel.errorMessage!,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.error,
                  ),
                )
              else if (viewModel.products.isEmpty)
                Text(
                  '暂无商品',
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.textSecondary,
                  ),
                )
              else ...[
                if (viewModel.productActionError != null) ...[
                  Text(
                    viewModel.productActionError!,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.error,
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                for (final product in viewModel.products) ...[
                  _AdminProductRow(
                    product: product,
                    isUpdatingProduct: viewModel.isUpdatingProduct,
                    isDeletingProduct: viewModel.isDeletingProduct,
                    onEdit: () => _showEditProductDialog(
                      context: context,
                      product: product,
                    ),
                    onDelete: () => _confirmDeleteProduct(
                      context: context,
                      product: product,
                    ),
                  ),
                  if (product != viewModel.products.last)
                    const Divider(height: 18, color: AppColors.border),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  void _showCreateProductDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => _CreateAdminProductDialog(viewModel: viewModel),
    );
  }

  void _showEditProductDialog({
    required BuildContext context,
    required AdminProduct product,
  }) {
    showDialog<void>(
      context: context,
      builder: (context) =>
          _EditAdminProductDialog(product: product, viewModel: viewModel),
    );
  }

  void _confirmDeleteProduct({
    required BuildContext context,
    required AdminProduct product,
  }) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${product.name}'),
        content: const Text('确认删除该商品？存在库存或流水时后端会拒绝删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('admin-confirm-delete-product-button'),
            onPressed: () => unawaited(_deleteProduct(context, product)),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteProduct(
    BuildContext context,
    AdminProduct product,
  ) async {
    final deleted = await viewModel.deleteProduct(product);
    if (deleted && context.mounted) {
      Navigator.of(context).pop();
    }
  }
}

final class _AdminProductRow extends StatelessWidget {
  const _AdminProductRow({
    required this.product,
    required this.isUpdatingProduct,
    required this.isDeletingProduct,
    required this.onEdit,
    required this.onDelete,
  });

  final AdminProduct product;
  final bool isUpdatingProduct;
  final bool isDeletingProduct;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final subtitleParts = [
      product.code,
      if (product.category.isNotEmpty) product.category,
      if (product.spec.isNotEmpty) product.spec,
      product.unit,
    ];

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                product.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodyMedium.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitleParts.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        RimsStatusChip(
          label: product.isActive ? '启用' : '停用',
          kind: product.isActive
              ? RimsStatusKind.success
              : RimsStatusKind.pending,
        ),
        const SizedBox(width: 4),
        IconButton(
          key: Key('admin-edit-product-${product.id}-button'),
          tooltip: '编辑商品',
          onPressed: isUpdatingProduct ? null : onEdit,
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          key: Key('admin-delete-product-${product.id}-button'),
          tooltip: '删除商品',
          onPressed: isDeletingProduct ? null : onDelete,
          icon: const Icon(Icons.delete_outline, color: AppColors.error),
        ),
      ],
    );
  }
}

final class _CreateAdminProductDialog extends StatefulWidget {
  const _CreateAdminProductDialog({required this.viewModel});

  final AdminProductsViewModel viewModel;

  @override
  State<_CreateAdminProductDialog> createState() =>
      _CreateAdminProductDialogState();
}

final class _CreateAdminProductDialogState
    extends State<_CreateAdminProductDialog> {
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _unitController = TextEditingController();
  final TextEditingController _categoryController = TextEditingController();
  final TextEditingController _specController = TextEditingController();
  final TextEditingController _barcodeController = TextEditingController();
  final TextEditingController _retailPriceController = TextEditingController();
  final TextEditingController _costPriceController = TextEditingController();
  String? _priceInputError;

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _unitController.dispose();
    _categoryController.dispose();
    _specController.dispose();
    _barcodeController.dispose();
    _retailPriceController.dispose();
    _costPriceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        return AlertDialog(
          title: const Text('创建商品'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const Key('admin-create-product-code-field'),
                  controller: _codeController,
                  enabled: !widget.viewModel.isCreatingProduct,
                  decoration: const InputDecoration(labelText: '商品编码'),
                ),
                TextField(
                  key: const Key('admin-create-product-name-field'),
                  controller: _nameController,
                  enabled: !widget.viewModel.isCreatingProduct,
                  decoration: const InputDecoration(labelText: '商品名称'),
                ),
                TextField(
                  key: const Key('admin-create-product-unit-field'),
                  controller: _unitController,
                  enabled: !widget.viewModel.isCreatingProduct,
                  decoration: const InputDecoration(labelText: '单位'),
                ),
                TextField(
                  key: const Key('admin-create-product-category-field'),
                  controller: _categoryController,
                  enabled: !widget.viewModel.isCreatingProduct,
                  decoration: const InputDecoration(labelText: '分类'),
                ),
                TextField(
                  key: const Key('admin-create-product-spec-field'),
                  controller: _specController,
                  enabled: !widget.viewModel.isCreatingProduct,
                  decoration: const InputDecoration(labelText: '规格'),
                ),
                TextField(
                  key: const Key('admin-create-product-barcode-field'),
                  controller: _barcodeController,
                  enabled: !widget.viewModel.isCreatingProduct,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '条码'),
                ),
                TextField(
                  key: const Key('admin-create-product-retail-price-field'),
                  controller: _retailPriceController,
                  enabled: !widget.viewModel.isCreatingProduct,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _clearPriceInputError(),
                  decoration: const InputDecoration(labelText: '零售价'),
                ),
                TextField(
                  key: const Key('admin-create-product-cost-price-field'),
                  controller: _costPriceController,
                  enabled: !widget.viewModel.isCreatingProduct,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _clearPriceInputError(),
                  decoration: const InputDecoration(labelText: '成本价'),
                ),
                if (_formError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _formError!,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: widget.viewModel.isCreatingProduct
                  ? null
                  : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('admin-submit-create-product-button'),
              onPressed: widget.viewModel.isCreatingProduct
                  ? null
                  : () => unawaited(_submit(context)),
              child: Text(widget.viewModel.isCreatingProduct ? '创建中...' : '创建'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _submit(BuildContext context) async {
    final retailPrice = _parseOptionalPrice(_retailPriceController.text);
    final costPrice = _parseOptionalPrice(_costPriceController.text);
    if (retailPrice.hasInvalidToken || costPrice.hasInvalidToken) {
      setState(() {
        _priceInputError = '价格只能填写数字';
      });
      return;
    }

    setState(() {
      _priceInputError = null;
    });

    final created = await widget.viewModel.createProduct(
      CreateAdminProductRequest(
        code: _codeController.text,
        name: _nameController.text,
        unit: _unitController.text,
        category: _categoryController.text,
        spec: _specController.text,
        barcode: _barcodeController.text,
        retailPrice: retailPrice.value,
        costPrice: costPrice.value,
      ),
    );

    if (created && context.mounted) {
      Navigator.of(context).pop();
    }
  }

  void _clearPriceInputError() {
    if (_priceInputError != null) {
      setState(() {
        _priceInputError = null;
      });
    }
  }

  String? get _formError => _priceInputError ?? widget.viewModel.formError;
}

final class _EditAdminProductDialog extends StatefulWidget {
  const _EditAdminProductDialog({
    required this.product,
    required this.viewModel,
  });

  final AdminProduct product;
  final AdminProductsViewModel viewModel;

  @override
  State<_EditAdminProductDialog> createState() =>
      _EditAdminProductDialogState();
}

final class _EditAdminProductDialogState
    extends State<_EditAdminProductDialog> {
  late final TextEditingController _codeController;
  late final TextEditingController _nameController;
  late final TextEditingController _unitController;
  late final TextEditingController _categoryController;
  late final TextEditingController _specController;
  late final TextEditingController _barcodeController;
  late final TextEditingController _retailPriceController;
  late final TextEditingController _costPriceController;
  late bool _isActive;
  String? _priceInputError;

  @override
  void initState() {
    super.initState();
    _codeController = TextEditingController(text: widget.product.code);
    _nameController = TextEditingController(text: widget.product.name);
    _unitController = TextEditingController(text: widget.product.unit);
    _categoryController = TextEditingController(text: widget.product.category);
    _specController = TextEditingController(text: widget.product.spec);
    _barcodeController = TextEditingController(text: widget.product.barcode);
    _retailPriceController = TextEditingController(
      text: _formatPrice(widget.product.retailPrice),
    );
    _costPriceController = TextEditingController(
      text: _formatPrice(widget.product.costPrice),
    );
    _isActive = widget.product.isActive;
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _unitController.dispose();
    _categoryController.dispose();
    _specController.dispose();
    _barcodeController.dispose();
    _retailPriceController.dispose();
    _costPriceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        return AlertDialog(
          title: Text('编辑 ${widget.product.name}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const Key('admin-edit-product-code-field'),
                  controller: _codeController,
                  enabled: !widget.viewModel.isUpdatingProduct,
                  decoration: const InputDecoration(labelText: '商品编码'),
                ),
                TextField(
                  key: const Key('admin-edit-product-name-field'),
                  controller: _nameController,
                  enabled: !widget.viewModel.isUpdatingProduct,
                  decoration: const InputDecoration(labelText: '商品名称'),
                ),
                TextField(
                  key: const Key('admin-edit-product-unit-field'),
                  controller: _unitController,
                  enabled: !widget.viewModel.isUpdatingProduct,
                  decoration: const InputDecoration(labelText: '单位'),
                ),
                TextField(
                  key: const Key('admin-edit-product-category-field'),
                  controller: _categoryController,
                  enabled: !widget.viewModel.isUpdatingProduct,
                  decoration: const InputDecoration(labelText: '分类'),
                ),
                TextField(
                  key: const Key('admin-edit-product-spec-field'),
                  controller: _specController,
                  enabled: !widget.viewModel.isUpdatingProduct,
                  decoration: const InputDecoration(labelText: '规格'),
                ),
                TextField(
                  key: const Key('admin-edit-product-barcode-field'),
                  controller: _barcodeController,
                  enabled: !widget.viewModel.isUpdatingProduct,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '条码'),
                ),
                TextField(
                  key: const Key('admin-edit-product-retail-price-field'),
                  controller: _retailPriceController,
                  enabled: !widget.viewModel.isUpdatingProduct,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _clearPriceInputError(),
                  decoration: const InputDecoration(labelText: '零售价'),
                ),
                TextField(
                  key: const Key('admin-edit-product-cost-price-field'),
                  controller: _costPriceController,
                  enabled: !widget.viewModel.isUpdatingProduct,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _clearPriceInputError(),
                  decoration: const InputDecoration(labelText: '成本价'),
                ),
                SwitchListTile(
                  key: const Key('admin-edit-product-status-switch'),
                  contentPadding: EdgeInsets.zero,
                  value: _isActive,
                  onChanged: widget.viewModel.isUpdatingProduct
                      ? null
                      : (value) => setState(() => _isActive = value),
                  title: const Text('启用商品'),
                ),
                if (_formError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _formError!,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: widget.viewModel.isUpdatingProduct
                  ? null
                  : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('admin-submit-edit-product-button'),
              onPressed: widget.viewModel.isUpdatingProduct
                  ? null
                  : () => unawaited(_submit(context)),
              child: Text(widget.viewModel.isUpdatingProduct ? '保存中...' : '保存'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _submit(BuildContext context) async {
    final retailPrice = _parseOptionalPrice(_retailPriceController.text);
    final costPrice = _parseOptionalPrice(_costPriceController.text);
    if (retailPrice.hasInvalidToken || costPrice.hasInvalidToken) {
      setState(() {
        _priceInputError = '价格只能填写数字';
      });
      return;
    }

    setState(() {
      _priceInputError = null;
    });

    final updated = await widget.viewModel.updateProduct(
      UpdateAdminProductRequest(
        id: widget.product.id,
        code: _codeController.text,
        name: _nameController.text,
        unit: _unitController.text,
        category: _categoryController.text,
        spec: _specController.text,
        barcode: _barcodeController.text,
        retailPrice: retailPrice.value,
        costPrice: costPrice.value,
        status: _isActive ? 1 : 0,
      ),
    );

    if (updated && context.mounted) {
      Navigator.of(context).pop();
    }
  }

  void _clearPriceInputError() {
    if (_priceInputError != null) {
      setState(() {
        _priceInputError = null;
      });
    }
  }

  String? get _formError => _priceInputError ?? widget.viewModel.formError;
}

_ParsedOptionalPrice _parseOptionalPrice(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return const _ParsedOptionalPrice(value: null, hasInvalidToken: false);
  }

  final price = double.tryParse(trimmed);
  if (price == null) {
    return const _ParsedOptionalPrice(value: null, hasInvalidToken: true);
  }

  return _ParsedOptionalPrice(value: price, hasInvalidToken: false);
}

final class _ParsedOptionalPrice {
  const _ParsedOptionalPrice({
    required this.value,
    required this.hasInvalidToken,
  });

  final double? value;
  final bool hasInvalidToken;
}

String _formatPrice(double? value) {
  if (value == null) {
    return '';
  }
  if (value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }

  return value.toString();
}
