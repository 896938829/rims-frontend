import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/events/app_event_bus.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_page_scaffold.dart';
import '../../../../core/widgets/rims_status_chip.dart';
import '../../../../routes/route_paths.dart';
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
import '../../../auth/domain/repositories/local_unlock_repository.dart';
import '../../../auth/presentation/view_models/biometric_unlock_view_model.dart';
import '../../../offline/domain/services/offline_ownership_service.dart';
import '../view_models/profile_security_view_model.dart';
import '../view_models/profile_view_model.dart';
import '../widgets/device_permissions_panel.dart';

typedef PreviewOfflineData =
    Future<OfflineClearPreview> Function({
      required String accountId,
      required OfflineClearCommand command,
    });
typedef ExecuteOfflineClear =
    Future<OfflineOwnershipReport> Function(OfflineClearPreview preview);

final class ProfilePage extends StatelessWidget {
  const ProfilePage({
    this.user,
    this.warehouse,
    this.warehouses = const [],
    this.onLogout,
    this.onLogoutRequested,
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
    this.previewOfflineData,
    this.executeOfflineClear,
    this.biometricSettingsRepository,
    super.key,
  });

  final AppUser? user;
  final Warehouse? warehouse;
  final List<Warehouse> warehouses;
  final VoidCallback? onLogout;
  final Future<OfflineOwnershipReport?> Function(DraftRetentionChoice choice)?
  onLogoutRequested;
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
  final PreviewOfflineData? previewOfflineData;
  final ExecuteOfflineClear? executeOfflineClear;
  final BiometricSettingsRepository? biometricSettingsRepository;

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
              biometricSettingsRepository: biometricSettingsRepository,
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
          if (effectiveViewModel != null) ...[
            const SizedBox(height: 14),
            _DataAndCacheCard(
              accountId: effectiveViewModel.user.id.toString(),
              previewOfflineData: previewOfflineData,
              executeOfflineClear: executeOfflineClear,
            ),
          ],
          const SizedBox(height: 14),
          _LogoutCard(onLogout: onLogout, onLogoutRequested: onLogoutRequested),
          const SizedBox(height: 14),
          const DevicePermissionsPanel(),
        ],
      ),
    );
  }
}

final class _DataAndCacheCard extends StatefulWidget {
  const _DataAndCacheCard({
    required this.accountId,
    this.previewOfflineData,
    this.executeOfflineClear,
  });

  final String accountId;
  final PreviewOfflineData? previewOfflineData;
  final ExecuteOfflineClear? executeOfflineClear;

  @override
  State<_DataAndCacheCard> createState() => _DataAndCacheCardState();
}

final class _DataAndCacheCardState extends State<_DataAndCacheCard> {
  bool _isRunning = false;
  String? _resultMessage;
  bool _resultIsFailure = false;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('数据与缓存', style: AppTextStyles.titleMedium),
          Material(
            type: MaterialType.transparency,
            child: ListTile(
              key: const Key('profile-draft-manager-entry'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.drafts_outlined),
              title: const Text('草稿管理'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(RoutePaths.drafts),
            ),
          ),
          Material(
            type: MaterialType.transparency,
            child: ListTile(
              key: const Key('profile-sync-center-entry'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sync),
              title: const Text('同步中心'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(RoutePaths.syncCenter),
            ),
          ),
          Material(
            type: MaterialType.transparency,
            child: ListTile(
              key: const Key('profile-clear-cache-command'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('清除缓存'),
              trailing: _isRunning
                  ? const Icon(Icons.hourglass_top)
                  : const Icon(Icons.chevron_right),
              onTap: _canRun
                  ? () => _runCommand(OfflineClearCommand.cache)
                  : null,
            ),
          ),
          Material(
            type: MaterialType.transparency,
            child: ListTile(
              key: const Key('profile-clear-offline-work-command'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.work_off_outlined),
              title: const Text('清除离线工作'),
              trailing: _isRunning
                  ? const Icon(Icons.hourglass_top)
                  : const Icon(Icons.chevron_right),
              onTap: _canRun
                  ? () => _runCommand(OfflineClearCommand.offlineWork)
                  : null,
            ),
          ),
          if (_resultMessage != null)
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 8),
              child: Text(
                _resultMessage!,
                key: const Key('profile-offline-clear-result'),
                style: AppTextStyles.bodySmall.copyWith(
                  color: _resultIsFailure ? AppColors.error : AppColors.success,
                ),
              ),
            ),
        ],
      ),
    );
  }

  bool get _canRun =>
      !_isRunning &&
      widget.previewOfflineData != null &&
      widget.executeOfflineClear != null;

  Future<void> _runCommand(OfflineClearCommand command) async {
    setState(() {
      _isRunning = true;
      _resultMessage = null;
    });
    try {
      var preview = await widget.previewOfflineData!(
        accountId: widget.accountId,
        command: command,
      );
      var requiresReconfirmation = false;
      while (true) {
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              command == OfflineClearCommand.cache ? '清除缓存' : '清除离线工作',
            ),
            content: _OfflineClearPreviewContent(
              preview: preview,
              requiresReconfirmation: requiresReconfirmation,
            ),
            actions: [
              TextButton(
                key: const Key('offline-clear-cancel'),
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('offline-clear-confirm'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('确认清除'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        final report = await widget.executeOfflineClear!(preview);
        if (!mounted) return;
        if (report.requiresReconfirmation) {
          preview = report.currentPreview!;
          requiresReconfirmation = true;
          continue;
        }
        setState(() {
          _resultIsFailure = !report.completed;
          _resultMessage = report.completed
              ? command == OfflineClearCommand.cache
                    ? '缓存已清除'
                    : '离线工作已清除'
              : report.failures.map((failure) => failure.message).join(' ');
        });
        return;
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _resultIsFailure = true;
        _resultMessage = '清理失败：${error.runtimeType}';
      });
    } finally {
      if (mounted) setState(() => _isRunning = false);
    }
  }
}

final class _OfflineClearPreviewContent extends StatelessWidget {
  const _OfflineClearPreviewContent({
    required this.preview,
    this.requiresReconfirmation = false,
  });

  final OfflineClearPreview preview;
  final bool requiresReconfirmation;

  @override
  Widget build(BuildContext context) {
    final counts = preview.counts;
    final lines = preview.command == OfflineClearCommand.cache
        ? [
            '缓存记录（含扫码查询缓存）：${counts.cacheEntries} 项',
            '已下载文件：${counts.downloads} 项',
            '不会删除草稿或同步操作记录',
          ]
        : [
            '草稿：${counts.drafts} 项',
            '同步操作记录（含待处理、失败和已完成证据）：${counts.outboxOperations} 项',
            '暂存附件：${counts.stagedTransfers} 项',
            '扫码会话：${counts.scanSessions} 项',
            '缓存记录和已下载文件将保留',
          ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (requiresReconfirmation)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('数据已变化，请重新确认'),
          ),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(line),
          ),
      ],
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
    this.biometricSettingsRepository,
  });

  final ProfileViewModel viewModel;
  final ValueChanged<Warehouse>? onWarehouseSelected;
  final bool isSwitchingWarehouse;
  final String? warehouseSwitchMessage;
  final BiometricSettingsRepository? biometricSettingsRepository;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Column(
        children: [
          _SettingRow(label: '个人信息', value: viewModel.userName),
          _SettingRow(
            label: '当前角色',
            value: viewModel.roleName,
            action: TextButton.icon(
              key: const Key('profile-device-sessions-entry'),
              onPressed: () => context.push(RoutePaths.deviceSessions),
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              icon: const Icon(Icons.devices_outlined, size: 20),
              label: const Text('登录设备'),
            ),
          ),
          _SettingRow(
            label: '账号安全',
            value: '二次验证',
            action: IconButton(
              key: const Key('profile-two-factor-entry'),
              onPressed: () => context.push(RoutePaths.secondFactorSettings),
              tooltip: '管理二次验证',
              icon: const Icon(Icons.security_outlined),
            ),
          ),
          if (biometricSettingsRepository case final repository?)
            _BiometricUnlockRow(repository: repository),
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

final class _LogoutCard extends StatefulWidget {
  const _LogoutCard({required this.onLogout, required this.onLogoutRequested});

  final VoidCallback? onLogout;
  final Future<OfflineOwnershipReport?> Function(DraftRetentionChoice choice)?
  onLogoutRequested;

  @override
  State<_LogoutCard> createState() => _LogoutCardState();
}

final class _LogoutCardState extends State<_LogoutCard> {
  bool _isRunning = false;
  String? _failureMessage;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextButton.icon(
            key: const Key('profile-logout-button'),
            onPressed: _isRunning
                ? null
                : widget.onLogoutRequested == null
                ? widget.onLogout
                : () => _requestLogout(context),
            icon: const Icon(Icons.logout, color: AppColors.error),
            label: Text(
              _isRunning ? '正在退出...' : '退出登录',
              style: AppTextStyles.bodyMedium.copyWith(
                color: AppColors.error,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (_failureMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                _failureMessage!,
                key: const Key('profile-logout-failure'),
                style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _requestLogout(BuildContext context) async {
    final requestLogout = widget.onLogoutRequested;
    final choice = await showDialog<DraftRetentionChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('请选择本机草稿的处理方式。其他缓存与离线工作将清除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('profile-logout-delete-drafts'),
            onPressed: () =>
                Navigator.of(context).pop(DraftRetentionChoice.delete),
            child: const Text('删除草稿'),
          ),
          FilledButton(
            key: const Key('profile-logout-retain-drafts'),
            onPressed: () =>
                Navigator.of(context).pop(DraftRetentionChoice.retainLocally),
            child: const Text('本机保留'),
          ),
        ],
      ),
    );
    if (choice == null || requestLogout == null) return;
    if (mounted) {
      setState(() {
        _isRunning = true;
        _failureMessage = null;
      });
    }
    try {
      final report = await requestLogout(choice);
      if (!mounted || report == null || report.completed) return;
      setState(() {
        _failureMessage = report.failures
            .map((failure) => failure.message)
            .join(' ');
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _failureMessage = '退出失败：${error.runtimeType}');
    } finally {
      if (mounted) setState(() => _isRunning = false);
    }
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
    _clearPasswordControllers();
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
    var changed = false;
    try {
      changed = await widget.viewModel.changePassword(
        oldPassword: _oldPasswordController.text,
        newPassword: _newPasswordController.text,
        confirmPassword: _confirmPasswordController.text,
      );
    } finally {
      if (mounted) {
        _clearPasswordControllers();
      }
    }

    if (changed && context.mounted) {
      Navigator.of(context).pop();
    }
  }

  void _clearPasswordControllers() {
    _oldPasswordController.clear();
    _newPasswordController.clear();
    _confirmPasswordController.clear();
  }
}

final class _BiometricUnlockRow extends StatefulWidget {
  const _BiometricUnlockRow({required this.repository});

  final BiometricSettingsRepository repository;

  @override
  State<_BiometricUnlockRow> createState() => _BiometricUnlockRowState();
}

final class _BiometricUnlockRowState extends State<_BiometricUnlockRow> {
  late final BiometricUnlockViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel = BiometricUnlockViewModel(repository: widget.repository);
    _viewModel.addListener(_refresh);
    _viewModel.load();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _viewModel.removeListener(_refresh);
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const Key('profile-biometric-unlock-toggle'),
          contentPadding: EdgeInsets.zero,
          title: const Text('本机生物识别解锁'),
          subtitle: const Text('仅解锁当前设备上已有且未过期的登录凭据'),
          secondary: const Icon(Icons.fingerprint),
          value: _viewModel.enabled,
          onChanged: _viewModel.loading ? null : _viewModel.setEnabled,
        ),
        if (_viewModel.errorMessage case final message?)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              message,
              style: AppTextStyles.bodySmall.copyWith(color: AppColors.error),
            ),
          ),
      ],
    );
  }
}

final class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.label, required this.value, this.action});

  final String label;
  final String value;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: action == null ? 11 : 0),
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
          if (action case final action?) ...[const SizedBox(width: 4), action],
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
