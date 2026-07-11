import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_status_chip.dart';
import '../../domain/entities/admin_user.dart';
import '../../domain/entities/admin_warehouse.dart';
import '../../domain/repositories/admin_repository.dart';
import '../view_models/admin_warehouses_view_model.dart';
import 'admin_pagination_control.dart';

final class AdminWarehousesPanel extends StatefulWidget {
  const AdminWarehousesPanel({
    this.repository,
    this.viewModel,
    this.eventBus,
    super.key,
  });

  final AdminRepository? repository;
  final AdminWarehousesViewModel? viewModel;
  final AppEventBus? eventBus;

  @override
  State<AdminWarehousesPanel> createState() => _AdminWarehousesPanelState();
}

final class _AdminWarehousesPanelState extends State<AdminWarehousesPanel> {
  late final AdminWarehousesViewModel viewModel;
  late final bool _ownsViewModel;

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    viewModel =
        widget.viewModel ??
        AdminWarehousesViewModel(
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
          key: const Key('profile-admin-warehouses-panel'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('仓库管理', style: AppTextStyles.titleMedium),
                  ),
                  IconButton(
                    key: const Key('admin-create-warehouse-button'),
                    tooltip: '创建仓库',
                    onPressed: viewModel.isCreatingWarehouse
                        ? null
                        : () => _showCreateWarehouseDialog(context),
                    icon: const Icon(Icons.add_business_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('admin-warehouses-search-field'),
                onChanged: (value) => unawaited(viewModel.updateQuery(value)),
                style: AppTextStyles.bodyMedium,
                decoration: const InputDecoration(
                  hintText: '搜索仓库编码或名称',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              if (viewModel.isLoading && viewModel.warehouses.isEmpty)
                Text(
                  '正在加载仓库...',
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
              else if (viewModel.warehouses.isEmpty)
                Text(
                  '暂无仓库',
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.textSecondary,
                  ),
                )
              else ...[
                if (viewModel.warehouseActionError != null) ...[
                  Text(
                    viewModel.warehouseActionError!,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.error,
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                for (final warehouse in viewModel.warehouses) ...[
                  _AdminWarehouseRow(
                    warehouse: warehouse,
                    isUpdatingWarehouse: viewModel.isUpdatingWarehouse,
                    isDeletingWarehouse: viewModel.isDeletingWarehouse,
                    onEdit: () => _showEditWarehouseDialog(
                      context: context,
                      warehouse: warehouse,
                    ),
                    onDelete: () => _confirmDeleteWarehouse(
                      context: context,
                      warehouse: warehouse,
                    ),
                    onManageUsers: () => _showWarehouseUsersDialog(
                      context: context,
                      warehouse: warehouse,
                    ),
                  ),
                  if (warehouse != viewModel.warehouses.last)
                    const Divider(height: 18, color: AppColors.border),
                ],
                const SizedBox(height: 10),
                AdminPaginationControl(
                  keyPrefix: 'admin-warehouses-load-more',
                  loaded: viewModel.warehouses.length,
                  total: viewModel.total,
                  hasMore: viewModel.hasMore,
                  isLoadingMore: viewModel.isLoadingMore,
                  hasFailure: viewModel.loadMoreFailure != null,
                  onLoadMore: viewModel.loadMore,
                  onRetry: viewModel.retryLoadMore,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  void _showCreateWarehouseDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => _CreateAdminWarehouseDialog(viewModel: viewModel),
    );
  }

  void _showEditWarehouseDialog({
    required BuildContext context,
    required AdminWarehouse warehouse,
  }) {
    showDialog<void>(
      context: context,
      builder: (context) =>
          _EditAdminWarehouseDialog(warehouse: warehouse, viewModel: viewModel),
    );
  }

  void _showWarehouseUsersDialog({
    required BuildContext context,
    required AdminWarehouse warehouse,
  }) {
    showDialog<void>(
      context: context,
      builder: (context) =>
          _WarehouseUsersDialog(warehouse: warehouse, viewModel: viewModel),
    );
  }

  void _confirmDeleteWarehouse({
    required BuildContext context,
    required AdminWarehouse warehouse,
  }) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${warehouse.name}'),
        content: const Text('确认删除该仓库？存在库存、单据或流水时后端会拒绝删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('admin-confirm-delete-warehouse-button'),
            onPressed: () => unawaited(_deleteWarehouse(context, warehouse)),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteWarehouse(
    BuildContext context,
    AdminWarehouse warehouse,
  ) async {
    final deleted = await viewModel.deleteWarehouse(warehouse);
    if (deleted && context.mounted) {
      Navigator.of(context).pop();
    }
  }
}

final class _AdminWarehouseRow extends StatelessWidget {
  const _AdminWarehouseRow({
    required this.warehouse,
    required this.isUpdatingWarehouse,
    required this.isDeletingWarehouse,
    required this.onEdit,
    required this.onDelete,
    required this.onManageUsers,
  });

  final AdminWarehouse warehouse;
  final bool isUpdatingWarehouse;
  final bool isDeletingWarehouse;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onManageUsers;

  @override
  Widget build(BuildContext context) {
    final subtitleParts = [
      warehouse.code,
      if (warehouse.address.isNotEmpty) warehouse.address,
      if (warehouse.contactPerson.isNotEmpty) warehouse.contactPerson,
    ];

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                warehouse.name,
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
          label: warehouse.isActive ? '启用' : '停用',
          kind: warehouse.isActive
              ? RimsStatusKind.success
              : RimsStatusKind.pending,
        ),
        const SizedBox(width: 4),
        IconButton(
          key: Key('admin-manage-warehouse-users-${warehouse.id}-button'),
          tooltip: '绑定用户',
          onPressed: onManageUsers,
          icon: const Icon(Icons.group_add_outlined),
        ),
        IconButton(
          key: Key('admin-edit-warehouse-${warehouse.id}-button'),
          tooltip: '编辑仓库',
          onPressed: isUpdatingWarehouse ? null : onEdit,
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          key: Key('admin-delete-warehouse-${warehouse.id}-button'),
          tooltip: '删除仓库',
          onPressed: isDeletingWarehouse ? null : onDelete,
          icon: const Icon(Icons.delete_outline, color: AppColors.error),
        ),
      ],
    );
  }
}

final class _CreateAdminWarehouseDialog extends StatefulWidget {
  const _CreateAdminWarehouseDialog({required this.viewModel});

  final AdminWarehousesViewModel viewModel;

  @override
  State<_CreateAdminWarehouseDialog> createState() =>
      _CreateAdminWarehouseDialogState();
}

final class _CreateAdminWarehouseDialogState
    extends State<_CreateAdminWarehouseDialog> {
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _addressController = TextEditingController();
  final TextEditingController _contactPersonController =
      TextEditingController();
  final TextEditingController _contactPhoneController = TextEditingController();

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _addressController.dispose();
    _contactPersonController.dispose();
    _contactPhoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        return AlertDialog(
          title: const Text('创建仓库'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const Key('admin-create-warehouse-code-field'),
                  controller: _codeController,
                  enabled: !widget.viewModel.isCreatingWarehouse,
                  decoration: const InputDecoration(labelText: '仓库编码'),
                ),
                TextField(
                  key: const Key('admin-create-warehouse-name-field'),
                  controller: _nameController,
                  enabled: !widget.viewModel.isCreatingWarehouse,
                  decoration: const InputDecoration(labelText: '仓库名称'),
                ),
                TextField(
                  key: const Key('admin-create-warehouse-address-field'),
                  controller: _addressController,
                  enabled: !widget.viewModel.isCreatingWarehouse,
                  decoration: const InputDecoration(labelText: '地址'),
                ),
                TextField(
                  key: const Key('admin-create-warehouse-contact-person-field'),
                  controller: _contactPersonController,
                  enabled: !widget.viewModel.isCreatingWarehouse,
                  decoration: const InputDecoration(labelText: '联系人'),
                ),
                TextField(
                  key: const Key('admin-create-warehouse-contact-phone-field'),
                  controller: _contactPhoneController,
                  enabled: !widget.viewModel.isCreatingWarehouse,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: '联系电话'),
                ),
                if (widget.viewModel.formError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    widget.viewModel.formError!,
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
              onPressed: widget.viewModel.isCreatingWarehouse
                  ? null
                  : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('admin-submit-create-warehouse-button'),
              onPressed: widget.viewModel.isCreatingWarehouse
                  ? null
                  : () => unawaited(_submit(context)),
              child: Text(
                widget.viewModel.isCreatingWarehouse ? '创建中...' : '创建',
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _submit(BuildContext context) async {
    final created = await widget.viewModel.createWarehouse(
      CreateAdminWarehouseRequest(
        code: _codeController.text,
        name: _nameController.text,
        address: _addressController.text,
        contactPerson: _contactPersonController.text,
        contactPhone: _contactPhoneController.text,
      ),
    );

    if (created && context.mounted) {
      Navigator.of(context).pop();
    }
  }
}

final class _EditAdminWarehouseDialog extends StatefulWidget {
  const _EditAdminWarehouseDialog({
    required this.warehouse,
    required this.viewModel,
  });

  final AdminWarehouse warehouse;
  final AdminWarehousesViewModel viewModel;

  @override
  State<_EditAdminWarehouseDialog> createState() =>
      _EditAdminWarehouseDialogState();
}

final class _EditAdminWarehouseDialogState
    extends State<_EditAdminWarehouseDialog> {
  late final TextEditingController _codeController;
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _contactPersonController;
  late final TextEditingController _contactPhoneController;
  late bool _isActive;

  @override
  void initState() {
    super.initState();
    _codeController = TextEditingController(text: widget.warehouse.code);
    _nameController = TextEditingController(text: widget.warehouse.name);
    _addressController = TextEditingController(text: widget.warehouse.address);
    _contactPersonController = TextEditingController(
      text: widget.warehouse.contactPerson,
    );
    _contactPhoneController = TextEditingController(
      text: widget.warehouse.contactPhone,
    );
    _isActive = widget.warehouse.isActive;
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _addressController.dispose();
    _contactPersonController.dispose();
    _contactPhoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        return AlertDialog(
          title: Text('编辑 ${widget.warehouse.name}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const Key('admin-edit-warehouse-code-field'),
                  controller: _codeController,
                  enabled: !widget.viewModel.isUpdatingWarehouse,
                  decoration: const InputDecoration(labelText: '仓库编码'),
                ),
                TextField(
                  key: const Key('admin-edit-warehouse-name-field'),
                  controller: _nameController,
                  enabled: !widget.viewModel.isUpdatingWarehouse,
                  decoration: const InputDecoration(labelText: '仓库名称'),
                ),
                TextField(
                  key: const Key('admin-edit-warehouse-address-field'),
                  controller: _addressController,
                  enabled: !widget.viewModel.isUpdatingWarehouse,
                  decoration: const InputDecoration(labelText: '地址'),
                ),
                TextField(
                  key: const Key('admin-edit-warehouse-contact-person-field'),
                  controller: _contactPersonController,
                  enabled: !widget.viewModel.isUpdatingWarehouse,
                  decoration: const InputDecoration(labelText: '联系人'),
                ),
                TextField(
                  key: const Key('admin-edit-warehouse-contact-phone-field'),
                  controller: _contactPhoneController,
                  enabled: !widget.viewModel.isUpdatingWarehouse,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: '联系电话'),
                ),
                SwitchListTile(
                  key: const Key('admin-edit-warehouse-status-switch'),
                  contentPadding: EdgeInsets.zero,
                  value: _isActive,
                  onChanged: widget.viewModel.isUpdatingWarehouse
                      ? null
                      : (value) => setState(() => _isActive = value),
                  title: const Text('启用仓库'),
                ),
                if (widget.viewModel.formError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    widget.viewModel.formError!,
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
              onPressed: widget.viewModel.isUpdatingWarehouse
                  ? null
                  : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('admin-submit-edit-warehouse-button'),
              onPressed: widget.viewModel.isUpdatingWarehouse
                  ? null
                  : () => unawaited(_submit(context)),
              child: Text(
                widget.viewModel.isUpdatingWarehouse ? '保存中...' : '保存',
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _submit(BuildContext context) async {
    final updated = await widget.viewModel.updateWarehouse(
      UpdateAdminWarehouseRequest(
        id: widget.warehouse.id,
        code: _codeController.text,
        name: _nameController.text,
        status: _isActive ? 1 : 0,
        address: _addressController.text,
        contactPerson: _contactPersonController.text,
        contactPhone: _contactPhoneController.text,
      ),
    );

    if (updated && context.mounted) {
      Navigator.of(context).pop();
    }
  }
}

final class _WarehouseUsersDialog extends StatefulWidget {
  const _WarehouseUsersDialog({
    required this.warehouse,
    required this.viewModel,
  });

  final AdminWarehouse warehouse;
  final AdminWarehousesViewModel viewModel;

  @override
  State<_WarehouseUsersDialog> createState() => _WarehouseUsersDialogState();
}

final class _WarehouseUsersDialogState extends State<_WarehouseUsersDialog> {
  final TextEditingController _userIdsController = TextEditingController();
  String? _userIdsInputError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.viewModel.loadWarehouseUsers(widget.warehouse));
      }
    });
  }

  @override
  void dispose() {
    _userIdsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        final users = widget.viewModel.usersForWarehouse(widget.warehouse.id);

        return AlertDialog(
          title: Text('${widget.warehouse.name} 用户'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const Key('admin-bind-warehouse-user-ids-field'),
                  controller: _userIdsController,
                  enabled: !widget.viewModel.isBindingWarehouseUsers,
                  keyboardType: TextInputType.number,
                  onChanged: (_) {
                    if (_userIdsInputError != null) {
                      setState(() {
                        _userIdsInputError = null;
                      });
                    }
                  },
                  decoration: const InputDecoration(
                    labelText: '用户 ID',
                    helperText: '多个 ID 用逗号或空格分隔',
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.maxFinite,
                  child: FilledButton(
                    key: const Key('admin-submit-bind-warehouse-users-button'),
                    onPressed: widget.viewModel.isBindingWarehouseUsers
                        ? null
                        : () => unawaited(_bindUsers()),
                    child: Text(
                      widget.viewModel.isBindingWarehouseUsers
                          ? '绑定中...'
                          : '绑定用户',
                    ),
                  ),
                ),
                if (_bindingError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _bindingError!,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.error,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                if (widget.viewModel.isLoadingWarehouseUsers)
                  Text(
                    '正在加载绑定用户...',
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  )
                else if (users.isEmpty)
                  Text(
                    '暂无绑定用户',
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  )
                else
                  for (final user in users)
                    _BoundWarehouseUserRow(
                      warehouse: widget.warehouse,
                      user: user,
                      viewModel: widget.viewModel,
                    ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _bindUsers() async {
    final parsedUserIds = _parseUserIds(_userIdsController.text);
    if (parsedUserIds.hasInvalidToken) {
      setState(() {
        _userIdsInputError = '用户 ID 只能填写正整数';
      });
      return;
    }

    setState(() {
      _userIdsInputError = null;
    });

    final bound = await widget.viewModel.bindWarehouseUsers(
      warehouse: widget.warehouse,
      userIds: parsedUserIds.userIds,
    );

    if (bound) {
      _userIdsController.clear();
    }
  }

  String? get _bindingError =>
      _userIdsInputError ?? widget.viewModel.userBindingError;
}

final class _BoundWarehouseUserRow extends StatelessWidget {
  const _BoundWarehouseUserRow({
    required this.warehouse,
    required this.user,
    required this.viewModel,
  });

  final AdminWarehouse warehouse;
  final AdminUser user;
  final AdminWarehousesViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            user.username,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.bodyMedium,
          ),
        ),
        IconButton(
          key: Key(
            'admin-unbind-warehouse-${warehouse.id}-user-${user.id}-button',
          ),
          tooltip: '解绑用户',
          onPressed: viewModel.isUnbindingWarehouseUser
              ? null
              : () => _confirmUnbindWarehouseUser(context),
          icon: const Icon(Icons.link_off, color: AppColors.error),
        ),
      ],
    );
  }

  void _confirmUnbindWarehouseUser(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('解绑 ${user.username}'),
        content: Text('确认将该用户从 ${warehouse.name} 解绑？解绑后该用户可能无法访问该仓库。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('admin-confirm-unbind-warehouse-user-button'),
            onPressed: () => unawaited(_unbindWarehouseUser(context)),
            child: const Text('解绑'),
          ),
        ],
      ),
    );
  }

  Future<void> _unbindWarehouseUser(BuildContext context) async {
    final unbound = await viewModel.unbindWarehouseUser(
      warehouse: warehouse,
      user: user,
    );
    if (unbound && context.mounted) {
      Navigator.of(context).pop();
    }
  }
}

_ParsedUserIds _parseUserIds(String value) {
  final userIds = <int>{};
  var hasInvalidToken = false;

  for (final rawItem in value.split(RegExp(r'[\s,，]+'))) {
    final item = rawItem.trim();
    if (item.isEmpty) {
      continue;
    }

    final userId = int.tryParse(item);
    if (userId == null || userId <= 0) {
      hasInvalidToken = true;
      continue;
    }

    userIds.add(userId);
  }

  return _ParsedUserIds(
    userIds: userIds.toList(growable: false),
    hasInvalidToken: hasInvalidToken,
  );
}

final class _ParsedUserIds {
  const _ParsedUserIds({required this.userIds, required this.hasInvalidToken});

  final List<int> userIds;
  final bool hasInvalidToken;
}
