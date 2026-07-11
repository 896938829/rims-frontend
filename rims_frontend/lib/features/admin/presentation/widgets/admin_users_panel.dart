import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/events/app_event_bus.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_status_chip.dart';
import '../../domain/entities/admin_user.dart';
import '../../domain/repositories/admin_repository.dart';
import '../view_models/admin_users_view_model.dart';
import 'admin_pagination_control.dart';

final class AdminUsersPanel extends StatefulWidget {
  const AdminUsersPanel({
    this.repository,
    this.viewModel,
    this.eventBus,
    super.key,
  });

  final AdminRepository? repository;
  final AdminUsersViewModel? viewModel;
  final AppEventBus? eventBus;

  @override
  State<AdminUsersPanel> createState() => _AdminUsersPanelState();
}

final class _AdminUsersPanelState extends State<AdminUsersPanel> {
  late final AdminUsersViewModel viewModel;
  late final bool _ownsViewModel;

  @override
  void initState() {
    super.initState();
    _ownsViewModel = widget.viewModel == null;
    viewModel =
        widget.viewModel ??
        AdminUsersViewModel(
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
          key: const Key('profile-admin-users-panel'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('用户管理', style: AppTextStyles.titleMedium),
                  ),
                  IconButton(
                    key: const Key('admin-create-user-button'),
                    tooltip: '创建用户',
                    onPressed: viewModel.isCreatingUser
                        ? null
                        : () => _showCreateUserDialog(context),
                    icon: const Icon(Icons.person_add_alt_1),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('admin-users-search-field'),
                onChanged: (value) => unawaited(viewModel.updateQuery(value)),
                style: AppTextStyles.bodyMedium,
                decoration: const InputDecoration(
                  hintText: '搜索用户',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              if (viewModel.isLoading && viewModel.users.isEmpty)
                Text(
                  '正在加载用户...',
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
              else if (viewModel.users.isEmpty)
                Text(
                  '暂无用户',
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.textSecondary,
                  ),
                )
              else if (viewModel.userActionError != null) ...[
                Text(
                  viewModel.userActionError!,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.error,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              for (final user in viewModel.users) ...[
                _AdminUserRow(
                  user: user,
                  isUpdatingUser: viewModel.isUpdatingUser,
                  isDeletingUser: viewModel.isDeletingUser,
                  isResettingPassword: viewModel.isResettingPassword,
                  onEdit: () =>
                      _showEditUserDialog(context: context, user: user),
                  onDelete: () =>
                      _confirmDeleteUser(context: context, user: user),
                  onResetPassword: () =>
                      _showResetPasswordDialog(context: context, user: user),
                ),
                if (user != viewModel.users.last)
                  const Divider(height: 18, color: AppColors.border),
              ],
              if (viewModel.users.isNotEmpty) ...[
                const SizedBox(height: 10),
                AdminPaginationControl(
                  keyPrefix: 'admin-users-load-more',
                  loaded: viewModel.users.length,
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

  void _showCreateUserDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => _CreateAdminUserDialog(viewModel: viewModel),
    );
  }

  void _showEditUserDialog({
    required BuildContext context,
    required AdminUser user,
  }) {
    showDialog<void>(
      context: context,
      builder: (context) =>
          _EditAdminUserDialog(user: user, viewModel: viewModel),
    );
  }

  void _showResetPasswordDialog({
    required BuildContext context,
    required AdminUser user,
  }) {
    showDialog<void>(
      context: context,
      builder: (context) =>
          _ResetUserPasswordDialog(user: user, viewModel: viewModel),
    );
  }

  void _confirmDeleteUser({
    required BuildContext context,
    required AdminUser user,
  }) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${user.username}'),
        content: const Text('确认删除该用户？存在业务数据时后端会拒绝删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('admin-confirm-delete-user-button'),
            onPressed: () => unawaited(_deleteUser(context, user)),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteUser(BuildContext context, AdminUser user) async {
    final deleted = await viewModel.deleteUser(user);
    if (deleted && context.mounted) {
      Navigator.of(context).pop();
    }
  }
}

final class _AdminUserRow extends StatelessWidget {
  const _AdminUserRow({
    required this.user,
    required this.isUpdatingUser,
    required this.isDeletingUser,
    required this.isResettingPassword,
    required this.onEdit,
    required this.onDelete,
    required this.onResetPassword,
  });

  final AdminUser user;
  final bool isUpdatingUser;
  final bool isDeletingUser;
  final bool isResettingPassword;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onResetPassword;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                user.username,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodyMedium.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                user.realName.isEmpty ? user.roleName : user.realName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        RimsStatusChip(
          label: user.isActive ? '启用' : '停用',
          kind: user.isActive ? RimsStatusKind.success : RimsStatusKind.pending,
        ),
        const SizedBox(width: 4),
        IconButton(
          key: Key('admin-edit-user-${user.id}-button'),
          tooltip: '编辑用户',
          onPressed: isUpdatingUser ? null : onEdit,
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          key: Key('admin-delete-user-${user.id}-button'),
          tooltip: '删除用户',
          onPressed: isDeletingUser ? null : onDelete,
          icon: const Icon(Icons.delete_outline, color: AppColors.error),
        ),
        IconButton(
          key: Key('admin-reset-password-${user.id}-button'),
          tooltip: '重置密码',
          onPressed: isResettingPassword ? null : onResetPassword,
          icon: const Icon(Icons.lock_reset),
        ),
      ],
    );
  }
}

final class _EditAdminUserDialog extends StatefulWidget {
  const _EditAdminUserDialog({required this.user, required this.viewModel});

  final AdminUser user;
  final AdminUsersViewModel viewModel;

  @override
  State<_EditAdminUserDialog> createState() => _EditAdminUserDialogState();
}

final class _EditAdminUserDialogState extends State<_EditAdminUserDialog> {
  late final TextEditingController _realNameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;
  late final TextEditingController _roleIdController;
  late bool _isActive;
  String? _roleIdInputError;

  @override
  void initState() {
    super.initState();
    _realNameController = TextEditingController(text: widget.user.realName);
    _phoneController = TextEditingController(text: widget.user.phone);
    _emailController = TextEditingController(text: widget.user.email);
    _roleIdController = TextEditingController(
      text: widget.user.roleId.toString(),
    );
    _isActive = widget.user.isActive;
  }

  @override
  void dispose() {
    _realNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _roleIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        return AlertDialog(
          title: Text('编辑 ${widget.user.username}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const Key('admin-edit-real-name-field'),
                  controller: _realNameController,
                  enabled: !widget.viewModel.isUpdatingUser,
                  decoration: const InputDecoration(labelText: '姓名'),
                ),
                TextField(
                  key: const Key('admin-edit-phone-field'),
                  controller: _phoneController,
                  enabled: !widget.viewModel.isUpdatingUser,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: '手机号'),
                ),
                TextField(
                  key: const Key('admin-edit-email-field'),
                  controller: _emailController,
                  enabled: !widget.viewModel.isUpdatingUser,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: '邮箱'),
                ),
                TextField(
                  key: const Key('admin-edit-role-id-field'),
                  controller: _roleIdController,
                  enabled: !widget.viewModel.isUpdatingUser,
                  keyboardType: TextInputType.number,
                  onChanged: (_) {
                    if (_roleIdInputError != null) {
                      setState(() {
                        _roleIdInputError = null;
                      });
                    }
                  },
                  decoration: const InputDecoration(labelText: '角色 ID'),
                ),
                SwitchListTile(
                  key: const Key('admin-edit-status-switch'),
                  contentPadding: EdgeInsets.zero,
                  value: _isActive,
                  onChanged: widget.viewModel.isUpdatingUser
                      ? null
                      : (value) => setState(() => _isActive = value),
                  title: const Text('启用账号'),
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
              onPressed: widget.viewModel.isUpdatingUser
                  ? null
                  : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('admin-submit-edit-user-button'),
              onPressed: widget.viewModel.isUpdatingUser
                  ? null
                  : () => unawaited(_submit(context)),
              child: Text(widget.viewModel.isUpdatingUser ? '保存中...' : '保存'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _submit(BuildContext context) async {
    final roleId = _parseOptionalPositiveRoleId(_roleIdController.text);
    if (roleId.hasInvalidToken) {
      setState(() {
        _roleIdInputError = '角色 ID 只能填写正整数';
      });
      return;
    }

    setState(() {
      _roleIdInputError = null;
    });

    final updated = await widget.viewModel.updateUser(
      UpdateAdminUserRequest(
        id: widget.user.id,
        realName: _realNameController.text,
        phone: _phoneController.text,
        email: _emailController.text,
        roleId: roleId.value,
        status: _isActive ? 1 : 0,
      ),
    );

    if (updated && context.mounted) {
      Navigator.of(context).pop();
    }
  }

  String? get _formError => _roleIdInputError ?? widget.viewModel.formError;
}

final class _CreateAdminUserDialog extends StatefulWidget {
  const _CreateAdminUserDialog({required this.viewModel});

  final AdminUsersViewModel viewModel;

  @override
  State<_CreateAdminUserDialog> createState() => _CreateAdminUserDialogState();
}

final class _CreateAdminUserDialogState extends State<_CreateAdminUserDialog> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _realNameController = TextEditingController();
  final TextEditingController _roleIdController = TextEditingController(
    text: '2',
  );
  String? _roleIdInputError;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _realNameController.dispose();
    _roleIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        return AlertDialog(
          title: const Text('创建用户'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const Key('admin-create-username-field'),
                  controller: _usernameController,
                  enabled: !widget.viewModel.isCreatingUser,
                  decoration: const InputDecoration(labelText: '用户名'),
                ),
                TextField(
                  key: const Key('admin-create-password-field'),
                  controller: _passwordController,
                  enabled: !widget.viewModel.isCreatingUser,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '初始密码'),
                ),
                TextField(
                  key: const Key('admin-create-real-name-field'),
                  controller: _realNameController,
                  enabled: !widget.viewModel.isCreatingUser,
                  decoration: const InputDecoration(labelText: '姓名'),
                ),
                TextField(
                  key: const Key('admin-create-role-id-field'),
                  controller: _roleIdController,
                  enabled: !widget.viewModel.isCreatingUser,
                  keyboardType: TextInputType.number,
                  onChanged: (_) {
                    if (_roleIdInputError != null) {
                      setState(() {
                        _roleIdInputError = null;
                      });
                    }
                  },
                  decoration: const InputDecoration(labelText: '角色 ID'),
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
              onPressed: widget.viewModel.isCreatingUser
                  ? null
                  : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('admin-submit-create-user-button'),
              onPressed: widget.viewModel.isCreatingUser
                  ? null
                  : () => unawaited(_submit(context)),
              child: Text(widget.viewModel.isCreatingUser ? '创建中...' : '创建'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _submit(BuildContext context) async {
    final roleId = _parseOptionalPositiveRoleId(_roleIdController.text);
    if (roleId.hasInvalidToken) {
      setState(() {
        _roleIdInputError = '角色 ID 只能填写正整数';
      });
      return;
    }

    setState(() {
      _roleIdInputError = null;
    });

    final created = await widget.viewModel.createUser(
      CreateAdminUserRequest(
        username: _usernameController.text,
        password: _passwordController.text,
        realName: _realNameController.text,
        roleId: roleId.value ?? 0,
      ),
    );

    if (created && context.mounted) {
      Navigator.of(context).pop();
    }
  }

  String? get _formError => _roleIdInputError ?? widget.viewModel.formError;
}

final class _ResetUserPasswordDialog extends StatefulWidget {
  const _ResetUserPasswordDialog({required this.user, required this.viewModel});

  final AdminUser user;
  final AdminUsersViewModel viewModel;

  @override
  State<_ResetUserPasswordDialog> createState() =>
      _ResetUserPasswordDialogState();
}

final class _ResetUserPasswordDialogState
    extends State<_ResetUserPasswordDialog> {
  final TextEditingController _passwordController = TextEditingController();

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        return AlertDialog(
          title: Text('重置 ${widget.user.username} 密码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('admin-reset-password-field'),
                controller: _passwordController,
                enabled: !widget.viewModel.isResettingPassword,
                obscureText: true,
                decoration: const InputDecoration(labelText: '新密码'),
              ),
              if (widget.viewModel.passwordActionError != null) ...[
                const SizedBox(height: 10),
                Text(
                  widget.viewModel.passwordActionError!,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.error,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: widget.viewModel.isResettingPassword
                  ? null
                  : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('admin-submit-reset-password-button'),
              onPressed: widget.viewModel.isResettingPassword
                  ? null
                  : () => unawaited(_confirmSubmit(context)),
              child: Text(
                widget.viewModel.isResettingPassword ? '重置中...' : '重置',
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmSubmit(BuildContext resetDialogContext) async {
    final newPassword = _passwordController.text;
    if (newPassword.trim().isEmpty) {
      await _submit(
        resetDialogContext: resetDialogContext,
        newPassword: newPassword,
      );
      return;
    }

    await showDialog<void>(
      context: resetDialogContext,
      builder: (confirmationContext) => AlertDialog(
        title: Text('确认重置 ${widget.user.username} 密码'),
        content: const Text('确认重置该用户密码？重置后该用户需要使用新密码登录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(confirmationContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('admin-confirm-reset-password-button'),
            onPressed: () => unawaited(
              _submit(
                confirmationContext: confirmationContext,
                resetDialogContext: resetDialogContext,
                newPassword: newPassword,
              ),
            ),
            child: const Text('确认重置'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit({
    BuildContext? confirmationContext,
    required BuildContext resetDialogContext,
    required String newPassword,
  }) async {
    final reset = await widget.viewModel.resetUserPassword(
      userId: widget.user.id,
      newPassword: newPassword,
    );

    if (confirmationContext != null && confirmationContext.mounted) {
      Navigator.of(confirmationContext).pop();
    }
    if (reset && resetDialogContext.mounted) {
      Navigator.of(resetDialogContext).pop();
    }
  }
}

_ParsedOptionalRoleId _parseOptionalPositiveRoleId(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return const _ParsedOptionalRoleId(value: null, hasInvalidToken: false);
  }

  final roleId = int.tryParse(trimmed);
  if (roleId == null || roleId <= 0) {
    return const _ParsedOptionalRoleId(value: null, hasInvalidToken: true);
  }

  return _ParsedOptionalRoleId(value: roleId, hasInvalidToken: false);
}

final class _ParsedOptionalRoleId {
  const _ParsedOptionalRoleId({
    required this.value,
    required this.hasInvalidToken,
  });

  final int? value;
  final bool hasInvalidToken;
}
