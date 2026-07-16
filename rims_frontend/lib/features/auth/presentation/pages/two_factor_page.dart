import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/rims_card.dart';
import '../view_models/two_factor_view_model.dart';

final class TwoFactorPage extends StatefulWidget {
  const TwoFactorPage({
    required this.viewModel,
    this.onLoginCompleted,
    this.onChallengeTerminated,
    this.disposeViewModel = true,
    super.key,
  });

  final TwoFactorViewModel viewModel;
  final VoidCallback? onLoginCompleted;
  final VoidCallback? onChallengeTerminated;
  final bool disposeViewModel;

  @override
  State<TwoFactorPage> createState() => _TwoFactorPageState();
}

final class _TwoFactorPageState extends State<TwoFactorPage> {
  late final TextEditingController _codeController;
  late final TextEditingController _recoveryController;

  @override
  void initState() {
    super.initState();
    _codeController = TextEditingController();
    _recoveryController = TextEditingController();
    if (!widget.viewModel.isLoginChallenge) {
      widget.viewModel.loadStatus();
    }
  }

  @override
  void dispose() {
    _codeController.clear();
    _recoveryController.clear();
    _codeController.dispose();
    _recoveryController.dispose();
    if (widget.disposeViewModel) widget.viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('二次验证')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.viewModel,
          builder: (context, _) => SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: widget.viewModel.isLoginChallenge
                    ? _buildLoginChallenge(context)
                    : _buildManagement(context),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoginChallenge(BuildContext context) {
    final viewModel = widget.viewModel;
    return RimsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('验证你的身份', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '输入身份验证器中的动态验证码，或使用一条恢复代码。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.password_outlined),
                label: Text('动态验证码'),
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.key_outlined),
                label: Text('恢复代码'),
              ),
            ],
            selected: {viewModel.useRecoveryCode},
            onSelectionChanged: viewModel.isLoading
                ? null
                : (selection) {
                    viewModel.useRecoveryCode = selection.single;
                    _codeController.clear();
                    _recoveryController.clear();
                  },
          ),
          const SizedBox(height: 16),
          if (viewModel.useRecoveryCode)
            Semantics(
              label: '恢复代码',
              textField: true,
              child: TextField(
                key: const Key('two-factor-recovery-field'),
                controller: _recoveryController,
                enabled: !viewModel.isLoading,
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: viewModel.updateRecoveryCode,
                decoration: const InputDecoration(
                  labelText: '恢复代码',
                  hintText: 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEEE',
                ),
                onSubmitted: (_) => _completeLogin(),
              ),
            )
          else
            _TotpField(
              controller: _codeController,
              enabled: !viewModel.isLoading,
              onChanged: viewModel.updateCode,
              onSubmitted: _completeLogin,
            ),
          if (viewModel.errorMessage case final message?) ...[
            const SizedBox(height: 12),
            _ErrorText(message),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: viewModel.isLoading ? null : _completeLogin,
            icon: const Icon(Icons.verified_user_outlined),
            label: Text(viewModel.isLoading ? '验证中...' : '验证并登录'),
            style: _fullWidthButtonStyle,
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: viewModel.isLoading
                ? null
                : () => Navigator.of(context).maybePop(),
            style: _fullWidthButtonStyle,
            child: const Text('返回账号登录'),
          ),
        ],
      ),
    );
  }

  Widget _buildManagement(BuildContext context) {
    final viewModel = widget.viewModel;
    if (viewModel.recoveryCodes.isNotEmpty) {
      return _RecoveryCodesPanel(
        codes: viewModel.recoveryCodes,
        onAcknowledged: viewModel.acknowledgeRecoveryCodes,
      );
    }
    if (viewModel.enrollment case final enrollment?) {
      return RimsCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('添加身份验证器', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            const Text('在身份验证器中添加以下密钥，然后输入生成的 6 位验证码。'),
            const SizedBox(height: 12),
            SelectableText(
              enrollment.secret,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SelectableText(
              enrollment.otpAuthUri.toString(),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            _TotpField(
              controller: _codeController,
              enabled: !viewModel.isLoading,
              onChanged: viewModel.updateCode,
              onSubmitted: _confirmEnrollment,
            ),
            if (viewModel.errorMessage case final message?) ...[
              const SizedBox(height: 12),
              _ErrorText(message),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: viewModel.isLoading ? null : _confirmEnrollment,
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('确认启用'),
              style: _fullWidthButtonStyle,
            ),
          ],
        ),
      );
    }
    final status = viewModel.status;
    if (status == null || viewModel.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!status.enabled) {
      return RimsCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('身份验证器', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('启用后，密码登录还需要动态验证码或恢复代码。'),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: viewModel.beginEnrollment,
              icon: const Icon(Icons.add_moderator_outlined),
              label: const Text('启用二次验证'),
              style: _fullWidthButtonStyle,
            ),
          ],
        ),
      );
    }
    return RimsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.verified_user, color: AppColors.success),
            title: const Text('二次验证已启用'),
            subtitle: Text('剩余恢复代码：${status.recoveryCodesRemaining}'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _showProofDialog(regenerate: true),
            icon: const Icon(Icons.refresh),
            label: const Text('重新生成恢复代码'),
            style: _fullWidthButtonStyle,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _showProofDialog(regenerate: false),
            icon: const Icon(Icons.remove_moderator_outlined),
            label: const Text('停用二次验证'),
            style: _fullWidthButtonStyle,
          ),
          if (viewModel.errorMessage case final message?) ...[
            const SizedBox(height: 12),
            _ErrorText(message),
          ],
        ],
      ),
    );
  }

  Future<void> _completeLogin() async {
    final success = await widget.viewModel.completeLogin();
    _clearFactorControllers();
    if (success && mounted) widget.onLoginCompleted?.call();
    if (!success && mounted && widget.viewModel.challengeTerminated) {
      widget.onChallengeTerminated?.call();
    }
  }

  Future<void> _confirmEnrollment() async {
    await widget.viewModel.confirmEnrollment();
    _codeController.clear();
  }

  Future<void> _showProofDialog({required bool regenerate}) async {
    final password = TextEditingController();
    final factor = TextEditingController();
    var useRecovery = false;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => ListenableBuilder(
            listenable: widget.viewModel,
            builder: (context, _) => AlertDialog(
              title: Text(regenerate ? '重新生成恢复代码' : '停用二次验证'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      key: const Key('two-factor-proof-password'),
                      controller: password,
                      enabled: !widget.viewModel.isLoading,
                      obscureText: true,
                      onChanged: widget.viewModel.updatePassword,
                      decoration: const InputDecoration(labelText: '当前密码'),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('使用恢复代码'),
                      value: useRecovery,
                      onChanged: widget.viewModel.isLoading
                          ? null
                          : (value) {
                              factor.clear();
                              widget.viewModel.updateCode('');
                              widget.viewModel.updateRecoveryCode('');
                              setDialogState(() => useRecovery = value);
                            },
                    ),
                    TextField(
                      key: const Key('two-factor-proof-factor'),
                      controller: factor,
                      enabled: !widget.viewModel.isLoading,
                      keyboardType: useRecovery
                          ? TextInputType.text
                          : TextInputType.number,
                      inputFormatters: useRecovery
                          ? null
                          : [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(6),
                            ],
                      onChanged: useRecovery
                          ? widget.viewModel.updateRecoveryCode
                          : widget.viewModel.updateCode,
                      decoration: InputDecoration(
                        labelText: useRecovery ? '恢复代码' : '6位动态验证码',
                      ),
                    ),
                    if (widget.viewModel.errorMessage case final message?) ...[
                      const SizedBox(height: 12),
                      KeyedSubtree(
                        key: const Key('two-factor-proof-error'),
                        child: _ErrorText(message),
                      ),
                    ],
                    if (widget.viewModel.isLoading) ...[
                      const SizedBox(height: 16),
                      const LinearProgressIndicator(
                        key: Key('two-factor-proof-progress'),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: widget.viewModel.isLoading
                      ? null
                      : () => Navigator.pop(dialogContext),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: widget.viewModel.isLoading
                      ? null
                      : () async {
                          final success = regenerate
                              ? await widget.viewModel.regenerateRecoveryCodes()
                              : await widget.viewModel.disable();
                          password.clear();
                          factor.clear();
                          if (success && dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        },
                  child: Text(
                    widget.viewModel.isLoading
                        ? '提交中...'
                        : regenerate
                        ? '确认生成'
                        : '确认停用',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      password.clear();
      factor.clear();
      password.dispose();
      factor.dispose();
    }
  }

  void _clearFactorControllers() {
    _codeController.clear();
    _recoveryController.clear();
  }
}

final class _TotpField extends StatelessWidget {
  const _TotpField({
    required this.controller,
    required this.enabled,
    required this.onChanged,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '6位动态验证码',
      textField: true,
      child: TextField(
        key: const Key('two-factor-totp-field'),
        controller: controller,
        enabled: enabled,
        keyboardType: TextInputType.number,
        autofillHints: const [AutofillHints.oneTimeCode],
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
        ],
        onChanged: onChanged,
        onSubmitted: (_) => onSubmitted(),
        decoration: const InputDecoration(labelText: '6位动态验证码'),
      ),
    );
  }
}

final class _RecoveryCodesPanel extends StatelessWidget {
  const _RecoveryCodesPanel({
    required this.codes,
    required this.onAcknowledged,
  });

  final List<String> codes;
  final VoidCallback onAcknowledged;

  @override
  Widget build(BuildContext context) {
    return RimsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('保存恢复代码', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('这些代码只显示一次。每条代码只能使用一次。'),
          const SizedBox(height: 16),
          ...codes.map(
            (code) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SelectableText(code, textAlign: TextAlign.center),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onAcknowledged,
            icon: const Icon(Icons.check),
            label: const Text('我已安全保存'),
            style: _fullWidthButtonStyle,
          ),
        ],
      ),
    );
  }
}

final class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Text(
    message,
    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: Theme.of(context).colorScheme.error,
      fontWeight: FontWeight.w700,
    ),
  );
}

final ButtonStyle _fullWidthButtonStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size.fromHeight(48)),
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
  ),
);
