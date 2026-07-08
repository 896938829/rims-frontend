import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_status_chip.dart';
import '../../domain/entities/admin_role.dart';
import '../../domain/repositories/admin_repository.dart';
import '../view_models/admin_roles_view_model.dart';

final class AdminRolesPanel extends StatefulWidget {
  const AdminRolesPanel({
    this.repository,
    this.viewModel,
    this.eventBus,
    super.key,
  });

  final AdminRepository? repository;
  final AdminRolesViewModel? viewModel;
  final AppEventBus? eventBus;

  @override
  State<AdminRolesPanel> createState() => _AdminRolesPanelState();
}

final class _AdminRolesPanelState extends State<AdminRolesPanel> {
  late final AdminRolesViewModel viewModel;
  late final bool _ownsViewModel;

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    viewModel =
        widget.viewModel ??
        AdminRolesViewModel(
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
          key: const Key('profile-admin-roles-panel'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('角色权限', style: AppTextStyles.titleMedium),
                  ),
                  IconButton(
                    tooltip: '刷新角色权限',
                    onPressed: viewModel.isLoading
                        ? null
                        : () => unawaited(viewModel.load()),
                    icon: const Icon(Icons.refresh_outlined),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (viewModel.isLoading && viewModel.roles.isEmpty)
                Text(
                  '正在加载角色权限...',
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
              else if (viewModel.roles.isEmpty)
                Text(
                  '暂无角色',
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.textSecondary,
                  ),
                )
              else ...[
                if (viewModel.permissionActionError != null) ...[
                  Text(
                    viewModel.permissionActionError!,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: AppColors.error,
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                for (final role in viewModel.roles) ...[
                  _AdminRoleRow(
                    role: role,
                    permissionCount: role.permissionIds.length,
                    isSavingPermissions: viewModel.isSavingPermissions,
                    onManagePermissions: () =>
                        _showPermissionsDialog(context: context, role: role),
                  ),
                  if (role != viewModel.roles.last)
                    const Divider(height: 18, color: AppColors.border),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  void _showPermissionsDialog({
    required BuildContext context,
    required AdminRole role,
  }) {
    showDialog<void>(
      context: context,
      builder: (context) =>
          _RolePermissionsDialog(role: role, viewModel: viewModel),
    );
  }
}

final class _AdminRoleRow extends StatelessWidget {
  const _AdminRoleRow({
    required this.role,
    required this.permissionCount,
    required this.isSavingPermissions,
    required this.onManagePermissions,
  });

  final AdminRole role;
  final int permissionCount;
  final bool isSavingPermissions;
  final VoidCallback onManagePermissions;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                role.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodyMedium.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${role.code} · $permissionCount 个权限',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        RimsStatusChip(
          label: role.isActive ? '启用' : '停用',
          kind: role.isActive ? RimsStatusKind.success : RimsStatusKind.pending,
        ),
        const SizedBox(width: 4),
        IconButton(
          key: Key('admin-manage-role-permissions-${role.id}-button'),
          tooltip: '配置权限',
          onPressed: isSavingPermissions ? null : onManagePermissions,
          icon: const Icon(Icons.admin_panel_settings_outlined),
        ),
      ],
    );
  }
}

final class _RolePermissionsDialog extends StatefulWidget {
  const _RolePermissionsDialog({required this.role, required this.viewModel});

  final AdminRole role;
  final AdminRolesViewModel viewModel;

  @override
  State<_RolePermissionsDialog> createState() => _RolePermissionsDialogState();
}

final class _RolePermissionsDialogState extends State<_RolePermissionsDialog> {
  late final Set<int> _selectedPermissionIds;

  @override
  void initState() {
    super.initState();
    _selectedPermissionIds = widget.role.permissionIds.toSet();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        return AlertDialog(
          title: Text('${widget.role.name} 权限'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final permission in widget.viewModel.permissions)
                    CheckboxListTile(
                      key: Key(
                        'admin-role-${widget.role.id}-permission-${permission.id}-checkbox',
                      ),
                      contentPadding: EdgeInsets.zero,
                      value: _selectedPermissionIds.contains(permission.id),
                      onChanged: widget.viewModel.isSavingPermissions
                          ? null
                          : (selected) {
                              setState(() {
                                if (selected ?? false) {
                                  _selectedPermissionIds.add(permission.id);
                                } else {
                                  _selectedPermissionIds.remove(permission.id);
                                }
                              });
                            },
                      title: Text(permission.name),
                      subtitle: Text(
                        permission.group.isEmpty
                            ? permission.code
                            : '${permission.group} · ${permission.code}',
                      ),
                    ),
                  if (widget.viewModel.permissionActionError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      widget.viewModel.permissionActionError!,
                      style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: widget.viewModel.isSavingPermissions
                  ? null
                  : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('admin-submit-role-permissions-button'),
              onPressed: widget.viewModel.isSavingPermissions
                  ? null
                  : () => _confirmSavePermissions(context),
              child: Text(
                widget.viewModel.isSavingPermissions ? '保存中...' : '保存',
              ),
            ),
          ],
        );
      },
    );
  }

  void _confirmSavePermissions(BuildContext permissionsContext) {
    showDialog<void>(
      context: permissionsContext,
      builder: (confirmationContext) => AlertDialog(
        title: Text('保存 ${widget.role.name} 权限'),
        content: const Text('确认保存该角色的权限配置？保存后会影响对应用户可见功能和可执行操作。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(confirmationContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('admin-confirm-save-role-permissions-button'),
            onPressed: () => unawaited(
              _submit(
                confirmationContext: confirmationContext,
                permissionsContext: permissionsContext,
              ),
            ),
            child: const Text('确认保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit({
    required BuildContext confirmationContext,
    required BuildContext permissionsContext,
  }) async {
    final saved = await widget.viewModel.saveRolePermissions(
      role: widget.role,
      permissionIds: _selectedPermissionIds.toList(growable: false),
    );

    if (confirmationContext.mounted) {
      Navigator.of(confirmationContext).pop();
    }
    if (saved && permissionsContext.mounted) {
      Navigator.of(permissionsContext).pop();
    }
  }
}
