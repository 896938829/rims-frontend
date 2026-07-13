import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/entities/network_reachability.dart';
import '../view_models/offline_status_view_model.dart';

final class OfflineStatusBar extends StatelessWidget {
  const OfflineStatusBar({
    required this.viewModel,
    this.onOpenSyncCenter,
    super.key,
  });

  final OfflineStatusViewModel viewModel;
  final VoidCallback? onOpenSyncCenter;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final theme = Theme.of(context);
        final colors =
            theme.extension<OfflineStatusBandTheme>() ??
            (theme.brightness == Brightness.dark
                ? OfflineStatusBandTheme.dark
                : OfflineStatusBandTheme.light);
        return Semantics(
          container: true,
          explicitChildNodes: true,
          label: '网络状态：${viewModel.networkLabel}。${viewModel.dataAgeLabel}',
          child: ColoredBox(
            color: colors.background,
            child: SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _StatusText(
                      icon: _networkIcon,
                      label: viewModel.networkLabel,
                      color: _networkColor(colors),
                    ),
                    _StatusText(
                      icon: viewModel.isStale
                          ? Icons.history_toggle_off
                          : Icons.schedule_outlined,
                      label: viewModel.dataAgeLabel,
                      color: viewModel.isStale
                          ? colors.warningForeground
                          : colors.foreground,
                    ),
                    if (viewModel.queuedCount > 0)
                      _CountButton(
                        icon: Icons.cloud_upload_outlined,
                        label: '待同步 ${viewModel.queuedCount}',
                        semanticsLabel: '${viewModel.queuedCount} 项待同步，打开同步中心',
                        color: colors.foreground,
                        onPressed: onOpenSyncCenter,
                      ),
                    if (viewModel.attentionCount > 0)
                      _CountButton(
                        icon: Icons.report_problem_outlined,
                        label: '需处理 ${viewModel.attentionCount}',
                        semanticsLabel:
                            '${viewModel.attentionCount} 项需处理，打开同步中心',
                        color: colors.warningForeground,
                        onPressed: onOpenSyncCenter,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  IconData get _networkIcon => switch (viewModel.reachability) {
    NetworkReachability.checking => Icons.sync,
    NetworkReachability.offline => Icons.signal_wifi_connected_no_internet_4,
    NetworkReachability.unreachable => Icons.cloud_off_outlined,
    NetworkReachability.online => Icons.cloud_done_outlined,
  };

  Color _networkColor(OfflineStatusBandTheme colors) {
    return switch (viewModel.reachability) {
      NetworkReachability.checking => colors.foreground,
      NetworkReachability.offline ||
      NetworkReachability.unreachable => colors.warningForeground,
      NetworkReachability.online => colors.successForeground,
    };
  }
}

final class _StatusText extends StatelessWidget {
  const _StatusText({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 32),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

final class _CountButton extends StatelessWidget {
  const _CountButton({
    required this.icon,
    required this.label,
    required this.semanticsLabel,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final String semanticsLabel;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      button: true,
      excludeSemantics: true,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: color,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
