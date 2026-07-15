import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_text_styles.dart';
import '../../domain/entities/device_session.dart';
import '../../domain/repositories/auth_repository.dart';
import '../view_models/auth_session_controller.dart';
import '../view_models/device_sessions_view_model.dart';

final class DeviceSessionsPage extends StatefulWidget {
  const DeviceSessionsPage({
    required this.authRepository,
    required this.sessionController,
    super.key,
  });

  final AuthRepository authRepository;
  final AuthSessionController sessionController;

  @override
  State<DeviceSessionsPage> createState() => _DeviceSessionsPageState();
}

final class _DeviceSessionsPageState extends State<DeviceSessionsPage> {
  late final DeviceSessionsViewModel _viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel = DeviceSessionsViewModel(
      repository: widget.authRepository,
      runTerminalRevocation: (command) =>
          widget.sessionController.runSessionRevocation(
            authRepository: widget.authRepository,
            remoteRevocation: command,
          ),
    );
    unawaited(_viewModel.load());
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _viewModel,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('登录设备'),
          actions: [
            IconButton(
              tooltip: '刷新',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: _viewModel.isBusy
                  ? null
                  : () => unawaited(_viewModel.refresh()),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: _buildBody(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_viewModel.isInitialLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_viewModel.sessions.isEmpty && _viewModel.errorMessage != null) {
      return _LoadFailure(
        message: _viewModel.errorMessage!,
        onRetry: _viewModel.isBusy ? null : _viewModel.load,
      );
    }

    return RefreshIndicator(
      onRefresh: _viewModel.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (_viewModel.hasRetainedDataError)
            _RetainedError(
              message: _viewModel.errorMessage!,
              onRetry: _viewModel.isBusy ? null : _viewModel.refresh,
            ),
          if (_viewModel.sessions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: Text('暂无登录设备')),
            )
          else ...[
            for (final session in _viewModel.sessions) ...[
              _DeviceSessionCard(
                session: session,
                viewModel: _viewModel,
                onRevoke:
                    _viewModel.isBusy || !_viewModel.canRevokeSession(session)
                    ? null
                    : () => _confirmRevokeSession(session),
              ),
              const SizedBox(height: 10),
            ],
          ],
          const SizedBox(height: 4),
          OutlinedButton.icon(
            key: const Key('device-sessions-revoke-others'),
            onPressed: _viewModel.isBusy || !_viewModel.canRevokeOthers
                ? null
                : _confirmRevokeOthers,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            icon: const Icon(Icons.phonelink_erase_outlined),
            label: const Text('撤销其他设备'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('device-sessions-revoke-all'),
            onPressed: _viewModel.isBusy || _viewModel.sessions.isEmpty
                ? null
                : _confirmRevokeAll,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            icon: const Icon(Icons.logout),
            label: const Text('撤销全部设备'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRevokeSession(DeviceSession session) async {
    final confirmed = await _confirm(
      title: '撤销此设备？',
      message: session.current
          ? '撤销当前设备后需要重新登录，本机离线数据也会按安全策略清理。'
          : '此设备将立即退出登录。',
    );
    if (!confirmed || !mounted) return;
    final outcome = await _viewModel.revokeSession(session);
    await _handleOutcome(outcome, refreshAfterSuccess: !session.current);
  }

  Future<void> _confirmRevokeOthers() async {
    final confirmed = await _confirm(
      title: '撤销其他设备？',
      message: '除当前设备外，其他设备都将退出登录。',
    );
    if (!confirmed || !mounted) return;
    final outcome = await _viewModel.revokeOthers();
    await _handleOutcome(outcome, refreshAfterSuccess: true);
  }

  Future<void> _confirmRevokeAll() async {
    final confirmed = await _confirm(
      title: '撤销全部设备？',
      message: '包括当前设备在内的全部设备都将退出登录，本机离线数据也会按安全策略清理。',
    );
    if (!confirmed || !mounted) return;
    final outcome = await _viewModel.revokeAll();
    await _handleOutcome(outcome);
  }

  Future<bool> _confirm({
    required String title,
    required String message,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                key: const Key('device-sessions-cancel'),
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('device-sessions-confirm'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('确认撤销'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _handleOutcome(
    DeviceSessionsCommandOutcome outcome, {
    bool refreshAfterSuccess = false,
  }) async {
    if (!mounted) return;
    switch (outcome) {
      case DeviceSessionsCommandOutcome.completed:
        final message = _viewModel.successMessage;
        if (refreshAfterSuccess) await _viewModel.refresh();
        if (mounted && message != null) _showMessage(message);
      case DeviceSessionsCommandOutcome.terminal:
      case DeviceSessionsCommandOutcome.terminalWithCleanupDebt:
        break;
      case DeviceSessionsCommandOutcome.failed:
        final message = _viewModel.errorMessage;
        if (message != null) _showMessage(message, isError: true);
      case DeviceSessionsCommandOutcome.ignored:
        break;
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    final colors = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? colors.error : null,
      ),
    );
  }
}

final class _DeviceSessionCard extends StatelessWidget {
  const _DeviceSessionCard({
    required this.session,
    required this.viewModel,
    required this.onRevoke,
  });

  final DeviceSession session;
  final DeviceSessionsViewModel viewModel;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: Key('device-session-card-${session.id}'),
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        viewModel.deviceLabelFor(session),
                        style: AppTextStyles.titleMedium.copyWith(
                          color: colors.onSurface,
                        ),
                      ),
                      if (session.current)
                        Semantics(
                          label: '当前登录设备',
                          child: Chip(
                            visualDensity: VisualDensity.compact,
                            label: const Text('当前设备'),
                          ),
                        ),
                    ],
                  ),
                ),
                Semantics(
                  container: true,
                  button: true,
                  label: '撤销 ${viewModel.deviceLabelFor(session)}',
                  excludeSemantics: true,
                  child: IconButton(
                    key: Key('device-session-revoke-${session.id}'),
                    tooltip: '撤销 ${viewModel.deviceLabelFor(session)}',
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: onRevoke,
                    icon: const Icon(Icons.logout),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _MetadataLine(
              icon: Icons.devices_outlined,
              text: viewModel.platformLabelFor(session),
            ),
            _MetadataLine(
              icon: Icons.web_outlined,
              text: viewModel.userAgentLabelFor(session),
            ),
            _MetadataLine(
              icon: Icons.schedule_outlined,
              text: '最近使用 ${viewModel.lastUsedLabelFor(session)}',
            ),
            _MetadataLine(
              icon: Icons.login_outlined,
              text: '首次登录 ${viewModel.createdLabelFor(session)}',
            ),
            _MetadataLine(
              icon: Icons.event_outlined,
              text: '到期时间 ${viewModel.expiresLabelFor(session)}',
            ),
            if (viewModel.revokedLabelFor(session) case final revokedAt?)
              _MetadataLine(
                icon: Icons.block_outlined,
                text: '撤销时间 $revokedAt',
              ),
          ],
        ),
      ),
    );
  }
}

final class _MetadataLine extends StatelessWidget {
  const _MetadataLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: AppTextStyles.bodySmall)),
        ],
      ),
    );
  }
}

final class _RetainedError extends StatelessWidget {
  const _RetainedError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Expanded(child: Text(message)),
              IconButton(
                key: const Key('device-sessions-retry'),
                tooltip: '重试',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 36),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('device-sessions-retry'),
              onPressed: onRetry,
              style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
