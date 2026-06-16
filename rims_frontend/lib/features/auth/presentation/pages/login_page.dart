import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/resources/app_images.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/rims_card.dart';
import '../../../../core/widgets/rims_page_scaffold.dart';
import '../../../../routes/route_paths.dart';
import '../view_models/login_view_model.dart';

final class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  static const LoginViewModel _viewModel = LoginViewModel();

  @override
  Widget build(BuildContext context) {
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
                    const TextField(
                      decoration: InputDecoration(labelText: '账号'),
                    ),
                    const SizedBox(height: 12),
                    const TextField(
                      obscureText: true,
                      decoration: InputDecoration(labelText: '密码'),
                    ),
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: () => context.go(RoutePaths.shell),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text('进入静态演示'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
