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
    return AnimatedBuilder(
      animation: _viewModel,
      builder: (context, _) {
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
                        const SizedBox(height: 16),
                        TextField(
                          key: const Key('login-username-field'),
                          controller: _usernameController,
                          enabled: !_viewModel.isLoading,
                          onChanged: _viewModel.updateUsername,
                          decoration: const InputDecoration(labelText: '账号'),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('login-password-field'),
                          controller: _passwordController,
                          enabled: !_viewModel.isLoading,
                          obscureText: true,
                          onChanged: _viewModel.updatePassword,
                          decoration: const InputDecoration(labelText: '密码'),
                          onSubmitted: (_) => _submit(context),
                        ),
                        if (_viewModel.errorMessage != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            _viewModel.errorMessage!,
                            style: AppTextStyles.bodySmall.copyWith(
                              color: AppColors.error,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                        const SizedBox(height: 18),
                        FilledButton(
                          onPressed: _viewModel.isLoading
                              ? null
                              : () => _submit(context),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(48),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: Text(_viewModel.isLoading ? '登录中...' : '登录'),
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

  Future<void> _submit(BuildContext context) async {
    final success = await _viewModel.login();

    if (success && context.mounted) {
      context.go(RoutePaths.shell);
    }
  }
}
