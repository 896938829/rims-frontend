import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/auth/domain/entities/app_user.dart';
import 'package:rims_frontend/features/auth/domain/entities/auth_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/device_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/auth_session_controller.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/login_view_model.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/two_factor_view_model.dart';

void main() {
  test(
    'login challenge completes through prepared-session ownership path',
    () async {
      final repository = _ChallengeRepository();
      final controller = AuthSessionController();
      final login = LoginViewModel(
        authRepository: repository,
        sessionController: controller,
      );
      login.updateUsername('alice');
      login.updatePassword('secret');

      expect(await login.login(), isFalse);
      expect(controller.isAuthenticated, isFalse);
      final challenge = login.takeSecondFactorChallenge();
      expect(challenge, isNotNull);

      final secondFactor = TwoFactorViewModel.login(challenge: challenge!);
      secondFactor.updateCode('123456');
      expect(await secondFactor.completeLogin(), isTrue);
      expect(controller.isAuthenticated, isTrue);
      expect(repository.transaction.commits, 1);
      expect(repository.logoutCalls, 0);
    },
  );

  test('disposing login cancels challenge without remote logout', () async {
    final repository = _ChallengeRepository();
    final controller = AuthSessionController();
    final login = LoginViewModel(
      authRepository: repository,
      sessionController: controller,
    );
    login.updateUsername('alice');
    login.updatePassword('secret');
    await login.login();

    login.dispose();
    await Future<void>.delayed(Duration.zero);

    expect((repository.continuation as _PendingChallenge).cancelCalls, 1);
    expect(repository.logoutCalls, 0);
    expect(controller.isAuthenticated, isFalse);
  });

  test(
    'dispose while remote completion waits aborts late transaction',
    () async {
      final pending = Completer<Result<AuthSessionTransaction>>();
      final repository = _ChallengeRepository(
        continuation: _PendingChallenge(pending: pending),
      );
      final controller = AuthSessionController();
      final login =
          LoginViewModel(
              authRepository: repository,
              sessionController: controller,
            )
            ..updateUsername('alice')
            ..updatePassword('secret');
      await login.login();
      final secondFactor = TwoFactorViewModel.login(
        challenge: login.takeSecondFactorChallenge()!,
      )..updateCode('123456');

      final completion = secondFactor.completeLogin();
      secondFactor.dispose();
      pending.complete(Success(repository.transaction));

      expect(await completion, isFalse);
      expect(repository.transaction.aborts, 1);
      expect(repository.transaction.commits, 0);
      expect(controller.isAuthenticated, isFalse);
    },
  );

  test(
    'explicit cancel while remote completion waits aborts late transaction',
    () async {
      final pending = Completer<Result<AuthSessionTransaction>>();
      final repository = _ChallengeRepository(
        continuation: _PendingChallenge(pending: pending),
      );
      final controller = AuthSessionController();
      final login =
          LoginViewModel(
              authRepository: repository,
              sessionController: controller,
            )
            ..updateUsername('alice')
            ..updatePassword('secret');
      await login.login();
      final challenge = login.takeSecondFactorChallenge()!;

      final completion = challenge.complete(code: '123456');
      await challenge.cancel();
      pending.complete(Success(repository.transaction));

      expect((await completion).isFailure, isTrue);
      expect(repository.transaction.aborts, 1);
      expect(repository.transaction.commits, 0);
      expect(controller.isAuthenticated, isFalse);
    },
  );

  test('invalid OTP and transient network failure remain retryable', () async {
    final continuation = _RetryingChallenge();
    final repository = _ChallengeRepository(continuation: continuation);
    final controller = AuthSessionController();
    final login =
        LoginViewModel(
            authRepository: repository,
            sessionController: controller,
          )
          ..updateUsername('alice')
          ..updatePassword('secret');
    await login.login();
    final challenge = login.takeSecondFactorChallenge()!;

    expect((await challenge.complete(code: '111111')).isFailure, isTrue);
    expect((await challenge.complete(code: '222222')).isFailure, isTrue);
    expect((await challenge.complete(code: '333333')).isSuccess, isTrue);

    expect(continuation.completeCalls, 3);
    expect(controller.isAuthenticated, isTrue);
    expect(repository.transaction.commits, 1);
  });
}

final class _ChallengeRepository
    implements AuthRepository, SecondFactorTransactionalAuthRepository {
  _ChallengeRepository({PendingSecondFactorLogin? continuation})
    : continuation = continuation ?? _PendingChallenge();

  final PendingSecondFactorLogin continuation;
  late final transaction = continuation.transaction;
  int logoutCalls = 0;

  @override
  Future<Result<AuthLoginPreparation>> prepareLoginFlow({
    required String username,
    required String password,
  }) async => Success(SecondFactorAuthLoginPreparation(continuation));

  @override
  Future<void> logout() async {
    logoutCalls += 1;
  }

  @override
  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<Result<List<DeviceSession>>> listDeviceSessions() =>
      throw UnimplementedError();

  @override
  Future<Result<int>> revokeAllDeviceSessions() => throw UnimplementedError();

  @override
  Future<Result<void>> revokeDeviceSession(String sessionId) =>
      throw UnimplementedError();

  @override
  Future<Result<int>> revokeOtherDeviceSessions() => throw UnimplementedError();

  @override
  Future<Result<AuthSession?>> restoreSession() => throw UnimplementedError();

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) =>
      throw UnimplementedError();
}

final class _PendingChallenge implements PendingSecondFactorLogin {
  _PendingChallenge({this.pending});

  final transaction = _Transaction();
  final Completer<Result<AuthSessionTransaction>>? pending;
  int cancelCalls = 0;

  @override
  DateTime get expiresAt => DateTime.utc(2026, 7, 16, 12, 5);

  @override
  Future<Result<AuthSessionTransaction>> complete({
    String? code,
    String? recoveryCode,
  }) => pending?.future ?? Future.value(Success(transaction));

  @override
  Future<void> cancel() async {
    cancelCalls += 1;
  }
}

final class _RetryingChallenge implements PendingSecondFactorLogin {
  final transaction = _Transaction();
  int completeCalls = 0;

  @override
  DateTime get expiresAt => DateTime.utc(2026, 7, 16, 12, 5);

  @override
  Future<Result<AuthSessionTransaction>> complete({
    String? code,
    String? recoveryCode,
  }) async {
    completeCalls += 1;
    if (completeCalls == 1) {
      return const FailureResult(AuthenticationFailure(message: '验证码无效'));
    }
    if (completeCalls == 2) {
      return const FailureResult(NetworkFailure(message: '网络暂时不可用'));
    }
    return Success(transaction);
  }

  @override
  Future<void> cancel() async {}
}

extension on PendingSecondFactorLogin {
  _Transaction get transaction => switch (this) {
    _PendingChallenge(:final transaction) => transaction,
    _RetryingChallenge(:final transaction) => transaction,
    _ => throw StateError('Unknown test continuation'),
  };
}

final class _Transaction implements AuthSessionTransaction {
  int commits = 0;
  int aborts = 0;

  @override
  final AuthSession session = const AuthSession(
    accessToken: 'access-7',
    user: AppUser(
      id: 7,
      username: 'alice',
      realName: 'Alice',
      roleCode: 'operator',
      roleName: 'Operator',
    ),
    currentWarehouse: null,
    warehouses: [],
  );

  @override
  Future<Result<void>> abort() async {
    aborts += 1;
    return const Success(null);
  }

  @override
  Future<Result<void>> commit() async {
    commits += 1;
    return const Success(null);
  }
}
