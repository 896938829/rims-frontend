import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/auth/domain/entities/second_factor.dart';
import 'package:rims_frontend/features/auth/domain/repositories/second_factor_repository.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/two_factor_view_model.dart';

void main() {
  group('TwoFactorViewModel management', () {
    test(
      'enrollment requires proof and exposes recovery codes until acknowledgement',
      () async {
        final repository = _FakeSecondFactorRepository();
        final viewModel = TwoFactorViewModel.management(repository: repository);

        await viewModel.loadStatus();
        expect(viewModel.status?.enabled, isFalse);
        expect(await viewModel.beginEnrollment(), isTrue);
        expect(viewModel.enrollment?.secret, 'JBSWY3DPEHPK3PXP');

        viewModel.updateCode('123456');
        expect(await viewModel.confirmEnrollment(), isTrue);
        expect(viewModel.recoveryCodes, ['AAAAA-BBBBB-CCCCC-DDDDD-EEEEEE']);
        expect(viewModel.code, isEmpty);

        viewModel.acknowledgeRecoveryCodes();
        expect(viewModel.recoveryCodes, isEmpty);
        expect(viewModel.status?.enabled, isTrue);
      },
    );

    test(
      'regenerate and disable require password plus exactly one factor and clear secrets',
      () async {
        final repository = _FakeSecondFactorRepository(enabled: true);
        final viewModel = TwoFactorViewModel.management(repository: repository);
        await viewModel.loadStatus();

        viewModel.updatePassword('Password-2026');
        expect(await viewModel.regenerateRecoveryCodes(), isFalse);
        expect(repository.regenerateCalls, 0);

        viewModel.updateRecoveryCode('AAAAA-BBBBB-CCCCC-DDDDD-EEEEEE');
        expect(await viewModel.regenerateRecoveryCodes(), isTrue);
        expect(repository.regenerateCalls, 1);
        expect(viewModel.password, isEmpty);
        expect(viewModel.recoveryCode, isEmpty);

        viewModel.acknowledgeRecoveryCodes();
        viewModel.updatePassword('Password-2026');
        viewModel.updateCode('654321');
        expect(await viewModel.disable(), isTrue);
        expect(repository.disableCalls, 1);
        expect(viewModel.status?.enabled, isFalse);
        expect(viewModel.password, isEmpty);
        expect(viewModel.code, isEmpty);
      },
    );

    test(
      'generation guard ignores late completion and dispose clears secret state',
      () async {
        final repository = _FakeSecondFactorRepository();
        final pending = Completer<Result<TOTPEnrollment>>();
        repository.pendingEnrollment = pending;
        final viewModel = TwoFactorViewModel.management(repository: repository);

        final future = viewModel.beginEnrollment();
        viewModel.updatePassword('secret-password');
        viewModel.updateCode('123456');
        viewModel.dispose();
        pending.complete(Success(repository.enrollment));

        expect(await future, isFalse);
        expect(viewModel.password, isEmpty);
        expect(viewModel.code, isEmpty);
        expect(viewModel.enrollment, isNull);
      },
    );
  });

  group('TwoFactorViewModel login challenge', () {
    test(
      'requires one valid factor and completes without exposing tokens',
      () async {
        final challenge = _FakeLoginChallenge();
        final viewModel = TwoFactorViewModel.login(challenge: challenge);

        viewModel.updateCode('12345');
        expect(await viewModel.completeLogin(), isFalse);
        expect(challenge.completeCalls, 0);

        viewModel.updateCode('123456');
        expect(await viewModel.completeLogin(), isTrue);
        expect(challenge.completeCalls, 1);
        expect(challenge.lastCode, '123456');
        expect(challenge.lastRecoveryCode, isNull);
        expect(viewModel.code, isEmpty);
      },
    );

    test(
      'recovery completion is one-shot and disposal cancels continuation',
      () async {
        final challenge = _FakeLoginChallenge();
        final viewModel = TwoFactorViewModel.login(challenge: challenge);

        viewModel.useRecoveryCode = true;
        viewModel.updateRecoveryCode('AAAAA-BBBBB-CCCCC-DDDDD-EEEEEE');
        expect(await viewModel.completeLogin(), isTrue);
        expect(await viewModel.completeLogin(), isFalse);
        expect(challenge.completeCalls, 1);

        viewModel.dispose();
        expect(challenge.cancelCalls, 1);
        expect(viewModel.recoveryCode, isEmpty);
      },
    );

    test(
      'late completion is ignored after disposal and secrets are cleared',
      () async {
        final pending = Completer<Result<void>>();
        final challenge = _FakeLoginChallenge(pending: pending);
        final viewModel = TwoFactorViewModel.login(challenge: challenge);
        viewModel.updateCode('654321');

        final completion = viewModel.completeLogin();
        viewModel.dispose();
        pending.complete(const Success(null));

        expect(await completion, isFalse);
        expect(viewModel.code, isEmpty);
        expect(challenge.cancelCalls, 1);
      },
    );
  });
}

final class _FakeLoginChallenge implements SecondFactorLoginChallenge {
  _FakeLoginChallenge({this.pending});

  final Completer<Result<void>>? pending;
  int completeCalls = 0;
  int cancelCalls = 0;
  String? lastCode;
  String? lastRecoveryCode;

  @override
  DateTime get expiresAt => DateTime.utc(2026, 7, 16, 12, 5);

  @override
  Future<Result<void>> complete({String? code, String? recoveryCode}) {
    completeCalls += 1;
    lastCode = code;
    lastRecoveryCode = recoveryCode;
    return pending?.future ?? Future.value(const Success(null));
  }

  @override
  Future<void> cancel() async {
    cancelCalls += 1;
  }
}

final class _FakeSecondFactorRepository implements SecondFactorRepository {
  _FakeSecondFactorRepository({bool enabled = false})
    : status = SecondFactorStatus(
        enabled: enabled,
        pending: false,
        recoveryCodesRemaining: enabled ? 8 : 0,
      );

  SecondFactorStatus status;
  final enrollment = TOTPEnrollment(
    secret: 'JBSWY3DPEHPK3PXP',
    otpAuthUri: Uri.parse('otpauth://totp/RIMS:test?secret=JBSWY3DPEHPK3PXP'),
    expiresAt: DateTime.utc(2026, 7, 16, 12, 10),
  );
  Completer<Result<TOTPEnrollment>>? pendingEnrollment;
  int regenerateCalls = 0;
  int disableCalls = 0;

  @override
  Future<Result<SecondFactorStatus>> getStatus() async => Success(status);

  @override
  Future<Result<TOTPEnrollment>> beginEnrollment() =>
      pendingEnrollment?.future ?? Future.value(Success(enrollment));

  @override
  Future<Result<RecoveryCodeSet>> confirmEnrollment(String code) async {
    status = const SecondFactorStatus(
      enabled: true,
      pending: false,
      recoveryCodesRemaining: 1,
    );
    return const Success(RecoveryCodeSet(['AAAAA-BBBBB-CCCCC-DDDDD-EEEEEE']));
  }

  @override
  Future<Result<RecoveryCodeSet>> regenerateRecoveryCodes(
    SecondFactorProof proof,
  ) async {
    regenerateCalls += 1;
    return const Success(RecoveryCodeSet(['FFFFF-GGGGG-HHHHH-IIIII-JJJJJJ']));
  }

  @override
  Future<Result<void>> disable(SecondFactorProof proof) async {
    disableCalls += 1;
    status = const SecondFactorStatus(
      enabled: false,
      pending: false,
      recoveryCodesRemaining: 0,
    );
    return const Success(null);
  }
}
