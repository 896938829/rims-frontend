import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/resources/app_images.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_page_scaffold.dart';
import '../../../../routes/route_paths.dart';
import '../../domain/repositories/auth_repository.dart';
import '../view_models/auth_session_controller.dart';
import '../view_models/login_view_model.dart';

final class LoginPage extends StatefulWidget {
  const LoginPage({
    required this.authRepository,
    required this.sessionController,
    super.key,
  });

  final AuthRepository authRepository;
  final AuthSessionController sessionController;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

final class _LoginPageState extends State<LoginPage> {
  late final LoginViewModel _viewModel;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;

  @override
  void initState() {
    super.initState();
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
    _viewModel = LoginViewModel(
      authRepository: widget.authRepository,
      sessionController: widget.sessionController,
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_viewModel, widget.sessionController]),
      builder: (context, _) {
        final isRestoringSession = widget.sessionController.isRestoring;
        final sessionMessage = isRestoringSession
            ? '正在恢复登录状态...'
            : widget.sessionController.sessionMessage;

        return Scaffold(
          body: RimsPageScaffold(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  Text(_viewModel.title, style: AppTextStyles.headingLarge),
                  const SizedBox(height: 8),
                  Text(_viewModel.subtitle, style: AppTextStyles.bodyMedium),
                  const SizedBox(height: 20),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset(
                      AppImages.homeWarehouseHero,
                      height: 190,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 18),
                  RimsCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('登录', style: AppTextStyles.headingMedium),
                        const SizedBox(height: 6),
                        Text(
                          _viewModel.warehouseHint,
                          style: AppTextStyles.bodySmall,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '账号由管理员创建，请使用分配的账号登录',
                          style: AppTextStyles.bodySmall.copyWith(
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (sessionMessage != null)
                          _AuthInfoMessage(message: sessionMessage),
                        _LoginForm(
                          viewModel: _viewModel,
                          usernameController: _usernameController,
                          passwordController: _passwordController,
                          isRestoringSession: isRestoringSession,
                          onSubmit: () => _submitLogin(context),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _submitLogin(BuildContext context) async {
    final success = await _viewModel.login();

    if (success && context.mounted) {
      context.go(RoutePaths.shell);
    }
  }
}

final class _LoginForm extends StatelessWidget {
  const _LoginForm({
    required this.viewModel,
    required this.usernameController,
    required this.passwordController,
    required this.isRestoringSession,
    required this.onSubmit,
  });

  final LoginViewModel viewModel;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final bool isRestoringSession;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('login-username-field'),
          controller: usernameController,
          enabled: !viewModel.isLoading && !isRestoringSession,
          onChanged: viewModel.updateUsername,
          decoration: const InputDecoration(labelText: '账号'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('login-password-field'),
          controller: passwordController,
          enabled: !viewModel.isLoading && !isRestoringSession,
          obscureText: true,
          onChanged: viewModel.updatePassword,
          decoration: const InputDecoration(labelText: '密码'),
          onSubmitted: (_) => onSubmit(),
        ),
        if (viewModel.errorMessage != null)
          _AuthErrorMessage(message: viewModel.errorMessage!),
        const SizedBox(height: 18),
        FilledButton(
          onPressed: viewModel.isLoading || isRestoringSession
              ? null
              : onSubmit,
          style: _primaryButtonStyle,
          child: Text(viewModel.isLoading ? '登录中...' : '登录'),
        ),
      ],
    );
  }
}

final class _AuthErrorMessage extends StatelessWidget {
  const _AuthErrorMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        message,
        style: AppTextStyles.bodySmall.copyWith(
          color: AppColors.error,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

final class _AuthInfoMessage extends StatelessWidget {
  const _AuthInfoMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        message,
        style: AppTextStyles.bodySmall.copyWith(
          color: AppColors.warning,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

ButtonStyle get _primaryButtonStyle {
  return FilledButton.styleFrom(
    backgroundColor: AppColors.primary,
    foregroundColor: Colors.white,
    minimumSize: const Size.fromHeight(48),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  );
}
