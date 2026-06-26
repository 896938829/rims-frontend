import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_page_scaffold.dart';
import '../../../../core/widgets/rims_section_header.dart';
import '../../../../core/widgets/rims_status_chip.dart';
import '../../../auth/domain/entities/app_user.dart';
import '../../../auth/domain/entities/warehouse.dart';
import '../view_models/profile_view_model.dart';
import '../widgets/api_guard_chip_group.dart';
import '../widgets/permission_group_card.dart';

final class ProfilePage extends StatelessWidget {
  const ProfilePage({
    this.user,
    this.warehouse,
    this.onLogout,
    this.viewModel,
    super.key,
  });

  final AppUser? user;
  final Warehouse? warehouse;
  final VoidCallback? onLogout;
  final ProfileViewModel? viewModel;

  @override
  Widget build(BuildContext context) {
    final effectiveViewModel = viewModel;

    return RimsPageScaffold(
      key: const Key('tab-body-profile'),
      child: ListView(
        children: [
          if (effectiveViewModel == null && user == null)
            const _MissingSessionCard()
          else
            _UserIdentityCard(
              viewModel:
                  effectiveViewModel ??
                  ProfileViewModel(user: user!, warehouse: warehouse),
            ),
          const SizedBox(height: 14),
          if (effectiveViewModel != null || user != null)
            _SettingsCard(
              viewModel:
                  effectiveViewModel ??
                  ProfileViewModel(user: user!, warehouse: warehouse),
            ),
          const SizedBox(height: 14),
          _LogoutCard(onLogout: onLogout),
          const SizedBox(height: 20),
          const RimsSectionHeader(title: 'API 守卫'),
          const SizedBox(height: 10),
          RimsCard(
            child: ApiGuardChipGroup(
              guards:
                  (effectiveViewModel ??
                          (user == null
                              ? null
                              : ProfileViewModel(
                                  user: user!,
                                  warehouse: warehouse,
                                )))
                      ?.apiGuards ??
                  const [],
            ),
          ),
          const SizedBox(height: 20),
          const RimsSectionHeader(title: '后端模块'),
          const SizedBox(height: 10),
          RimsCard(
            child: ApiGuardChipGroup(
              guards:
                  (effectiveViewModel ??
                          (user == null
                              ? null
                              : ProfileViewModel(
                                  user: user!,
                                  warehouse: warehouse,
                                )))
                      ?.backendModules ??
                  const [],
              kind: RimsStatusKind.pending,
            ),
          ),
          const SizedBox(height: 20),
          const RimsSectionHeader(title: '角色与权限'),
          const SizedBox(height: 10),
          for (final group
              in (effectiveViewModel ??
                          (user == null
                              ? null
                              : ProfileViewModel(
                                  user: user!,
                                  warehouse: warehouse,
                                )))
                      ?.permissionGroups ??
                  const <PermissionGroup>[]) ...[
            PermissionGroupCard(group: group),
            const SizedBox(height: 10),
          ],
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
  const _SettingsCard({required this.viewModel});

  final ProfileViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Column(
        children: [
          _SettingRow(label: '个人信息', value: viewModel.userName),
          _SettingRow(label: '当前角色', value: viewModel.roleName),
          _SettingRow(
            label: viewModel.canSwitchWarehouse ? '切换仓库' : '当前仓库',
            value: viewModel.warehouseName,
          ),
          const _SettingRow(label: '通知设置', value: '已开启'),
        ],
      ),
    );
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
