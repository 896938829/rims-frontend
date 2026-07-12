import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';

final class DevicePermissionsPanel extends StatelessWidget {
  const DevicePermissionsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      child: Column(
        key: const Key('device-permissions-panel'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: const [
          Text('设备与权限', style: AppTextStyles.titleMedium),
          SizedBox(height: 6),
          _CapabilityRow(
            icon: Icons.photo_camera_outlined,
            title: '相机',
            detail: '扫码和拍照时按需请求；拒绝后仍可手动输入或选择文件。',
          ),
          _CapabilityRow(
            icon: Icons.photo_library_outlined,
            title: '相册',
            detail: '通过 Android 系统选择器读取你选中的图片，不申请广泛存储权限。',
          ),
          _CapabilityRow(
            icon: Icons.attach_file,
            title: '文件',
            detail: '通过 Android 系统选择器读取你选中的文件，不扫描设备目录。',
          ),
          _CapabilityRow(
            icon: Icons.notifications_none,
            title: '通知',
            detail: '通知功能尚未启用，当前不会请求通知权限。',
          ),
          _CapabilityRow(
            icon: Icons.storage_outlined,
            title: '本地空间',
            detail: '空间不足或权限被撤销时，待处理附件会保留失败状态供重试。',
          ),
        ],
      ),
    );
  }
}

final class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTextStyles.bodyMedium),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
