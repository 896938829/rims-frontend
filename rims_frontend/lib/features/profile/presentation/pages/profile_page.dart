import 'package:flutter/material.dart';

import '../../../../core/events/app_event_bus.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_page_scaffold.dart';
import '../../../../core/widgets/rims_status_chip.dart';
import '../../../admin/domain/repositories/admin_repository.dart';
import '../../../admin/presentation/widgets/admin_products_panel.dart';
import '../../../admin/presentation/widgets/admin_roles_panel.dart';
import '../../../admin/presentation/widgets/admin_users_panel.dart';
import '../../../admin/presentation/widgets/admin_warehouses_panel.dart';
import '../../../attachments/domain/repositories/attachments_repository.dart';
import '../../../attachments/domain/services/attachment_picker.dart';
import '../../../attachments/domain/services/attachment_share_service.dart';
import '../../../attachments/domain/services/attachment_staging_store.dart';
import '../../../auth/domain/entities/app_user.dart';
import '../../../auth/domain/entities/warehouse.dart';
import '../view_models/profile_security_view_model.dart';
import '../view_models/profile_view_model.dart';

final class ProfilePage extends StatelessWidget {
  const ProfilePage({
    this.user,
    this.warehouse,
    this.warehouses = const [],
    this.onLogout,
    this.onWarehouseSelected,
    this.isSwitchingWarehouse = false,
    this.warehouseSwitchMessage,
    this.viewModel,
    this.adminRepository,
    this.eventBus,
    this.attachmentsRepository,
    this.attachmentPicker,
    this.attachmentStagingStore,
    this.attachmentShareService,
    this.attachmentUserId,
    super.key,
  });

  final AppUser? user;
  final Warehouse? warehouse;
  final List<Warehouse> warehouses;
  final VoidCallback? onLogout;
  final ValueChanged<Warehouse>? onWarehouseSelected;
  final bool isSwitchingWarehouse;
  final String? warehouseSwitchMessage;
  final ProfileViewModel? viewModel;
  final AdminRepository? adminRepository;
  final AppEventBus? eventBus;
  final AttachmentsRepository? attachmentsRepository;
  final AttachmentPicker? attachmentPicker;
  final AttachmentStagingStore? attachmentStagingStore;
  final AttachmentShareService? attachmentShareService;
  final String? attachmentUserId;

  @override
  Widget build(BuildContext context) {
    final effectiveViewModel =
        viewModel ??
        (user == null
            ? null
            : ProfileViewModel(
                user: user!,
                warehouse: warehouse,
                warehouses: warehouses,
              ));

    return RimsPageScaffold(
      key: const Key('tab-body-profile'),
      child: ListView(
        children: [
          if (effectiveViewModel == null && user == null)
            const _MissingSessionCard()
          else
            _UserIdentityCard(viewModel: effectiveViewModel!),
          const SizedBox(height: 14),
          if (effectiveViewModel != null)
            _SettingsCard(
              viewModel: effectiveViewModel,
              onWarehouseSelected: onWarehouseSelected,
              isSwitchingWarehouse: isSwitchingWarehouse,
              warehouseSwitchMessage: warehouseSwitchMessage,
            ),
          if (effectiveViewModel != null && adminRepository != null) ...[
            const SizedBox(height: 14),
            _AccountSecurityCard(repository: adminRepository!),
          ],
          if (effectiveViewModel != null &&
              effectiveViewModel.user.isAdmin &&
              adminRepository != null) ...[
            const SizedBox(height: 14),
            KeyedSubtree(
              key: const Key('profile-admin-users'),
              child: AdminUsersPanel(
                repository: adminRepository,
                eventBus: eventBus,
              ),
            ),
            const SizedBox(height: 14),
            KeyedSubtree(
              key: const Key('profile-admin-products'),
              child: AdminProductsPanel(
                repository: adminRepository,
                eventBus: eventBus,
                attachmentsRepository: attachmentsRepository,
                attachmentPicker: attachmentPicker,
                attachmentStagingStore: attachmentStagingStore,
                attachmentShareService: attachmentShareService,
                attachmentUserId: attachmentUserId,
              ),
            ),
            const SizedBox(height: 14),
            KeyedSubtree(
              key: const Key('profile-admin-warehouses'),
              child: AdminWarehousesPanel(
                repository: adminRepository,
                eventBus: eventBus,
              ),
            ),
            const SizedBox(height: 14),
            AdminRolesPanel(repository: adminRepository, eventBus: eventBus),
          ],
          const SizedBox(height: 14),
          _LogoutCard(onLogout: onLogout),
        ],
      ),
    );
  }
}

final class _MissingSessionCard extends StatelessWidget {
  const _MissingSessionCard();

  @override
  Widget build(BuildContext context) {
    return const RimsCard(
      child: Text('未加载账号信息', style: AppTextStyles.bodyMedium),
    );
  }
}

final class _UserIdentityCard extends StatelessWidget {
  const _UserIdentityCard({required this.viewModel});

  final ProfileViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(14),
            ),
            child: SizedBox(
              width: 58,
              height: 58,
              child: Center(
                child: Text(
                  viewModel.userName.characters.first,
                  style: AppTextStyles.headingMedium.copyWith(
                    color: AppColors.surface,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  viewModel.userName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.headingMedium,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    RimsStatusChip(
                      label: viewModel.roleName,
                      kind: RimsStatusKind.info,
                    ),
                    Text(viewModel.workId, style: AppTextStyles.bodySmall),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.viewModel,
    this.onWarehouseSelected,
    this.isSwitchingWarehouse = false,
    this.warehouseSwitchMessage,
  });

  final ProfileViewModel viewModel;
  final ValueChanged<Warehouse>? onWarehouseSelected;
  final bool isSwitchingWarehouse;
  final String? warehouseSwitchMessage;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Column(
        children: [
          _SettingRow(label: '个人信息', value: viewModel.userName),
          _SettingRow(label: '当前角色', value: viewModel.roleName),
          if (viewModel.canSwitchWarehouse)
            _WarehouseSelectorRow(
              viewModel: viewModel,
              onWarehouseSelected: onWarehouseSelected,
              isSwitchingWarehouse: isSwitchingWarehouse,
              warehouseSwitchMessage: warehouseSwitchMessage,
            )
          else
            _SettingRow(label: '当前仓库', value: viewModel.warehouseName),
          if (viewModel.showsAssignedWarehouses)
            KeyedSubtree(
              key: const Key('profile-assigned-warehouses'),
              child: _AssignedWarehousesRow(
                value: viewModel.assignedWarehouseNames,
              ),
            ),
        ],
      ),
    );
  }
}

final class _WarehouseSelectorRow extends StatelessWidget {
  const _WarehouseSelectorRow({
    required this.viewModel,
    this.onWarehouseSelected,
    this.isSwitchingWarehouse = false,
    this.warehouseSwitchMessage,
  });

  final ProfileViewModel viewModel;
  final ValueChanged<Warehouse>? onWarehouseSelected;
  final bool isSwitchingWarehouse;
  final String? warehouseSwitchMessage;

  @override
  Widget build(BuildContext context) {
    final selectedWarehouse = _selectedWarehouse;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '切换仓库',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyMedium,
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: DropdownButton<int>(
                  key: const Key('profile-warehouse-selector'),
                  value: selectedWarehouse?.id,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  onChanged: isSwitchingWarehouse || onWarehouseSelected == null
                      ? null
                      : (warehouseId) {
                          final selected = _warehouseById(warehouseId);
                          if (selected != null) {
                            onWarehouseSelected?.call(selected);
                          }
                        },
                  items: [
                    for (final warehouse in viewModel.warehouses)
                      DropdownMenuItem<int>(
                        value: warehouse.id,
                        child: Text(
                          warehouse.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: AppTextStyles.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (isSwitchingWarehouse || warehouseSwitchMessage != null) ...[
            const SizedBox(height: 4),
            Text(
              isSwitchingWarehouse ? '正在切换仓库...' : warehouseSwitchMessage!,
              style: AppTextStyles.bodySmall.copyWith(
                color: isSwitchingWarehouse
                    ? AppColors.textSecondary
                    : AppColors.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Warehouse? get _selectedWarehouse {
    final currentId = viewModel.warehouse?.id;
    return _warehouseById(currentId);
  }

  Warehouse? _warehouseById(int? warehouseId) {
    if (warehouseId == null) {
      return null;
    }

    for (final warehouse in viewModel.warehouses) {
      if (warehouse.id == warehouseId) {
        return warehouse;
      }
    }

    return null;
  }
}

final class _LogoutCard extends StatelessWidget {
  const _LogoutCard({required this.onLogout});

  final VoidCallback? onLogout;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      padding: const EdgeInsets.all(10),
      child: TextButton.icon(
        key: const Key('profile-logout-button'),
        onPressed: onLogout,
        icon: const Icon(Icons.logout, color: AppColors.error),
        label: Text(
          '退出登录',
          style: AppTextStyles.bodyMedium.copyWith(
            color: AppColors.error,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

final class _AccountSecurityCard extends StatefulWidget {
  const _AccountSecurityCard({required this.repository});

  final AdminRepository repository;

  @override
  State<_AccountSecurityCard> createState() => _AccountSecurityCardState();
}

final class _AccountSecurityCardState extends State<_AccountSecurityCard> {
  late final ProfileSecurityViewModel viewModel;

  @override
  void initState() {
    super.initState();
    viewModel = ProfileSecurityViewModel(repository: widget.repository);
  }

  @override
  void dispose() {
    viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: viewModel,
      builder: (context, _) {
        return RimsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('账号安全', style: AppTextStyles.titleMedium),
                  ),
                  TextButton.icon(
                    key: const Key('profile-change-password-button'),
                    onPressed: viewModel.isChangingPassword
                        ? null
                        : () => _showChangePasswordDialog(context),
                    icon: const Icon(Icons.lock_outline),
                    label: const Text('修改密码'),
                  ),
                ],
              ),
              if (viewModel.passwordMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  viewModel.passwordMessage!,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: AppColors.success,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  void _showChangePasswordDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => _ChangePasswordDialog(viewModel: viewModel),
    );
  }
}

final class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog({required this.viewModel});

  final ProfileSecurityViewModel viewModel;

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

final class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final TextEditingController _oldPasswordController = TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  @override
  void dispose() {
    _oldPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.viewModel,
      builder: (context, _) {
        return AlertDialog(
          title: const Text('修改密码'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const Key('profile-old-password-field'),
                  controller: _oldPasswordController,
                  enabled: !widget.viewModel.isChangingPassword,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '原密码'),
                ),
                TextField(
                  key: const Key('profile-new-password-field'),
                  controller: _newPasswordController,
                  enabled: !widget.viewModel.isChangingPassword,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '新密码'),
                ),
                TextField(
                  key: const Key('profile-confirm-password-field'),
                  controller: _confirmPasswordController,
                  enabled: !widget.viewModel.isChangingPassword,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '确认新密码'),
                ),
                if (widget.viewModel.passwordError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    widget.viewModel.passwordError!,
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
              onPressed: widget.viewModel.isChangingPassword
                  ? null
                  : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('profile-submit-change-password-button'),
              onPressed: widget.viewModel.isChangingPassword
                  ? null
                  : () => _submit(context),
              child: Text(
                widget.viewModel.isChangingPassword ? '保存中...' : '保存',
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _submit(BuildContext context) async {
    final changed = await widget.viewModel.changePassword(
      oldPassword: _oldPasswordController.text,
      newPassword: _newPasswordController.text,
      confirmPassword: _confirmPasswordController.text,
    );

    if (changed && context.mounted) {
      Navigator.of(context).pop();
    }
  }
}

final class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodyMedium,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: AppTextStyles.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

final class _AssignedWarehousesRow extends StatelessWidget {
  const _AssignedWarehousesRow({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('可用仓库', style: AppTextStyles.bodyMedium),
          const SizedBox(height: 6),
          Text(value, style: AppTextStyles.bodySmall),
        ],
      ),
    );
  }
}
