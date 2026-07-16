import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/auth/domain/entities/second_factor.dart';
import 'package:rims_frontend/features/auth/domain/repositories/second_factor_repository.dart';
import 'package:rims_frontend/features/auth/presentation/pages/two_factor_page.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/two_factor_view_model.dart';

void main() {
  testWidgets('login challenge is accessible on narrow large-text layouts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final challenge = _LoginChallenge();
    final viewModel = TwoFactorViewModel.login(challenge: challenge);

    await tester.pumpWidget(
      MaterialApp(
        themeMode: ThemeMode.dark,
        darkTheme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: TwoFactorPage(viewModel: viewModel),
      ),
    );

    expect(find.text('二次验证'), findsOneWidget);
    expect(find.bySemanticsLabel('6位动态验证码'), findsWidgets);
    await tester.enterText(
      find.byKey(const Key('two-factor-totp-field')),
      '123456',
    );
    await tester.ensureVisible(find.widgetWithText(FilledButton, '验证并登录'));
    expect(
      tester.getSize(find.widgetWithText(FilledButton, '验证并登录')).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.widgetWithText(FilledButton, '验证并登录'));
    await tester.pump();

    expect(challenge.completeCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recovery mode has keyboard-safe scrolling and touch targets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final viewModel = TwoFactorViewModel.login(challenge: _LoginChallenge());

    await tester.pumpWidget(
      MaterialApp(home: TwoFactorPage(viewModel: viewModel)),
    );
    await tester.tap(find.text('恢复代码'));
    await tester.pump();

    expect(find.bySemanticsLabel('恢复代码'), findsWidgets);
    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'management shows recovery codes once and requires acknowledgement',
    (tester) async {
      final repository = _ManagementRepository();
      final viewModel = TwoFactorViewModel.management(repository: repository);
      await tester.pumpWidget(
        MaterialApp(home: TwoFactorPage(viewModel: viewModel)),
      );
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, '启用二次验证'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('two-factor-totp-field')),
        '123456',
      );
      await tester.tap(find.widgetWithText(FilledButton, '确认启用'));
      await tester.pump();

      expect(find.text('AAAAA-BBBBB-CCCCC-DDDDD-EEEEEE'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '我已安全保存'));
      await tester.pump();
      expect(find.text('AAAAA-BBBBB-CCCCC-DDDDD-EEEEEE'), findsNothing);
    },
  );

  testWidgets(
    'failed mutation immediately clears visible password and factor',
    (tester) async {
      final repository = _ManagementRepository(
        enabled: true,
        failMutation: true,
      );
      final viewModel = TwoFactorViewModel.management(repository: repository);
      await tester.pumpWidget(
        MaterialApp(home: TwoFactorPage(viewModel: viewModel)),
      );
      await tester.pump();

      await tester.tap(find.text('重新生成恢复代码'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('two-factor-proof-password')),
        'Password-2026',
      );
      await tester.enterText(
        find.byKey(const Key('two-factor-proof-factor')),
        '123456',
      );
      await tester.tap(find.text('确认生成'));
      await tester.pump();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('two-factor-proof-password')),
            )
            .controller
            ?.text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('two-factor-proof-factor')))
            .controller
            ?.text,
        isEmpty,
      );
    },
  );
}

final class _LoginChallenge implements SecondFactorLoginChallenge {
  int completeCalls = 0;

  @override
  DateTime get expiresAt => DateTime.utc(2026, 7, 16, 12, 5);

  @override
  Future<void> cancel() async {}

  @override
  Future<Result<void>> complete({String? code, String? recoveryCode}) async {
    completeCalls += 1;
    return const Success(null);
  }
}

final class _ManagementRepository implements SecondFactorRepository {
  _ManagementRepository({this.enabled = false, this.failMutation = false});

  final bool enabled;
  final bool failMutation;

  @override
  Future<Result<TOTPEnrollment>> beginEnrollment() async => Success(
    TOTPEnrollment(
      secret: 'JBSWY3DPEHPK3PXP',
      otpAuthUri: Uri.parse('otpauth://totp/RIMS:test?secret=JBSWY3DPEHPK3PXP'),
      expiresAt: DateTime.utc(2026, 7, 16, 12, 10),
    ),
  );

  @override
  Future<Result<RecoveryCodeSet>> confirmEnrollment(String code) async =>
      const Success(RecoveryCodeSet(['AAAAA-BBBBB-CCCCC-DDDDD-EEEEEE']));

  @override
  Future<Result<void>> disable(SecondFactorProof proof) async => failMutation
      ? const FailureResult(StateFailure(message: '验证失败'))
      : const Success(null);

  @override
  Future<Result<SecondFactorStatus>> getStatus() async => Success(
    SecondFactorStatus(
      enabled: enabled,
      pending: false,
      recoveryCodesRemaining: enabled ? 8 : 0,
    ),
  );

  @override
  Future<Result<RecoveryCodeSet>> regenerateRecoveryCodes(
    SecondFactorProof proof,
  ) async => failMutation
      ? const FailureResult(StateFailure(message: '验证失败'))
      : const Success(RecoveryCodeSet(['FFFFF-GGGGG-HHHHH-IIIII-JJJJJJ']));
}
