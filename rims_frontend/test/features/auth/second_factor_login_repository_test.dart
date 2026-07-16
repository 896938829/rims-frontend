import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:rims_frontend/features/auth/data/models/auth_models.dart';
import 'package:rims_frontend/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';

void main() {
  test(
    'challenge issues no credential until factor completion and transaction commit',
    () async {
      final storage = _OwnedTokenStorage();
      final remote = _ChallengeRemote();
      final repository =
          AuthRepositoryImpl(
                remoteDataSource: remote,
                secureStorage: storage,
                tokenOwnerFactory: () => 'owner-1',
                now: () => DateTime.utc(2026, 7, 16, 12),
              )
              as SecondFactorTransactionalAuthRepository;

      final start = await repository.prepareLoginFlow(
        username: 'alice',
        password: 'secret',
      );
      expect(await storage.readAccessToken(), isNull);
      final challenge =
          (start as Success<AuthLoginPreparation>).data
              as SecondFactorAuthLoginPreparation;

      final completed = await challenge.continuation.complete(code: '123456');
      expect(await storage.readAccessToken(), isNull);
      final transaction = (completed as Success<AuthSessionTransaction>).data;
      expect((await transaction.commit()).isSuccess, isTrue);
      expect(await storage.readAccessToken(), 'access-7');
    },
  );

  test(
    'cancelled and superseded challenges cannot publish credentials',
    () async {
      final storage = _OwnedTokenStorage();
      var owner = 0;
      final remote = _ChallengeRemote();
      final repository =
          AuthRepositoryImpl(
                remoteDataSource: remote,
                secureStorage: storage,
                tokenOwnerFactory: () => 'owner-${++owner}',
                now: () => DateTime.utc(2026, 7, 16, 12),
              )
              as SecondFactorTransactionalAuthRepository;

      final first =
          (await repository.prepareLoginFlow(
                        username: 'alice',
                        password: 'secret',
                      )
                      as Success<AuthLoginPreparation>)
                  .data
              as SecondFactorAuthLoginPreparation;
      await first.continuation.cancel();
      expect(
        (await first.continuation.complete(code: '123456')).isFailure,
        isTrue,
      );
      expect(remote.completeCalls, 0);

      final stale =
          (await repository.prepareLoginFlow(
                        username: 'alice',
                        password: 'secret',
                      )
                      as Success<AuthLoginPreparation>)
                  .data
              as SecondFactorAuthLoginPreparation;
      await repository.prepareLoginFlow(username: 'bob', password: 'secret');
      final staleCompletion = await stale.continuation.complete(code: '123456');
      expect(staleCompletion.isFailure, isTrue);
      expect(await storage.readAccessToken(), isNull);
    },
  );

  test(
    'cancelling while completion waits drops late tokens before storage',
    () async {
      final storage = _OwnedTokenStorage();
      final pending = Completer<Result<LoginResponseModel>>();
      final remote = _ChallengeRemote(pendingCompletion: pending);
      final repository =
          AuthRepositoryImpl(
                remoteDataSource: remote,
                secureStorage: storage,
                tokenOwnerFactory: () => 'owner-1',
                now: () => DateTime.utc(2026, 7, 16, 12),
              )
              as SecondFactorTransactionalAuthRepository;
      final challenge =
          (await repository.prepareLoginFlow(
                        username: 'alice',
                        password: 'secret',
                      )
                      as Success<AuthLoginPreparation>)
                  .data
              as SecondFactorAuthLoginPreparation;

      final completion = challenge.continuation.complete(code: '123456');
      await challenge.continuation.cancel();
      pending.complete(Success(_loginModel()));

      expect((await completion).isFailure, isTrue);
      expect(await storage.readAccessToken(), isNull);
    },
  );

  test(
    'invalid and network failures can retry while challenge is valid',
    () async {
      final storage = _OwnedTokenStorage();
      final remote = _ChallengeRemote(
        completionResults: [
          const FailureResult(AuthenticationFailure(message: '验证码无效')),
          const FailureResult(NetworkFailure(message: '网络暂时不可用')),
          Success(_loginModel()),
        ],
      );
      final repository =
          AuthRepositoryImpl(
                remoteDataSource: remote,
                secureStorage: storage,
                tokenOwnerFactory: () => 'owner-1',
                now: () => DateTime.utc(2026, 7, 16, 12),
              )
              as SecondFactorTransactionalAuthRepository;
      final challenge =
          (await repository.prepareLoginFlow(
                        username: 'alice',
                        password: 'secret',
                      )
                      as Success<AuthLoginPreparation>)
                  .data
              as SecondFactorAuthLoginPreparation;

      expect(
        (await challenge.continuation.complete(code: '111111')).isFailure,
        isTrue,
      );
      expect(
        (await challenge.continuation.complete(code: '222222')).isFailure,
        isTrue,
      );
      expect(
        (await challenge.continuation.complete(code: '333333')).isSuccess,
        isTrue,
      );
      expect(remote.completeCalls, 3);
    },
  );
}

final class _ChallengeRemote
    implements AuthRemoteDataSource, SecondFactorAuthRemoteDataSource {
  _ChallengeRemote({this.pendingCompletion, this.completionResults = const []});

  final Completer<Result<LoginResponseModel>>? pendingCompletion;
  final List<Result<LoginResponseModel>> completionResults;
  int completeCalls = 0;

  @override
  Future<Result<LoginStartResponseModel>> beginLogin({
    required String username,
    required String password,
  }) async => Success(
    LoginChallengeResponseModel(
      challenge: 'abcdefghijklmnopqrstuvwxyzABCDEFGH123456789',
      expiresAt: DateTime.utc(2026, 7, 16, 12, 5),
    ),
  );

  @override
  Future<Result<LoginResponseModel>> completeSecondFactorChallenge({
    required String challenge,
    String? code,
    String? recoveryCode,
  }) async {
    completeCalls += 1;
    if (pendingCompletion != null) return pendingCompletion!.future;
    if (completionResults.isNotEmpty) {
      return completionResults[completeCalls - 1];
    }
    return Success(_loginModel());
  }

  @override
  Future<Result<List<WarehouseModel>>> loadWarehouses({
    String? accessToken,
  }) async => const Success([]);

  @override
  Future<Result<LoginResponseModel>> login({
    required String username,
    required String password,
  }) async => Success(_loginModel());

  @override
  Future<Result<AppUserModel>> loadCurrentUser() => throw UnimplementedError();

  @override
  Future<Result<WarehouseModel?>> switchCurrentWarehouse(int warehouseId) =>
      throw UnimplementedError();

  @override
  Future<Result<TOTPEnrollmentModel>> beginSecondFactorEnrollment() =>
      throw UnimplementedError();

  @override
  Future<Result<RecoveryCodeSetModel>> confirmSecondFactorEnrollment({
    required String code,
  }) => throw UnimplementedError();

  @override
  Future<Result<void>> disableSecondFactor({
    required String password,
    String? code,
    String? recoveryCode,
  }) => throw UnimplementedError();

  @override
  Future<Result<SecondFactorStatusModel>> getSecondFactorStatus() =>
      throw UnimplementedError();

  @override
  Future<Result<RecoveryCodeSetModel>> regenerateSecondFactorRecoveryCodes({
    required String password,
    String? code,
    String? recoveryCode,
  }) => throw UnimplementedError();
}

LoginResponseModel _loginModel() => LoginResponseModel(
  token: 'access-7',
  user: const AppUserModel(
    id: 7,
    username: 'alice',
    realName: 'Alice',
    roleCode: 'operator',
    roleName: 'Operator',
  ),
);

final class _OwnedTokenStorage
    implements TokenStorage, AuthTokenTransactionStorage {
  int _latest = 0;
  String? _pending;
  String? _owner;
  int? _version;
  String? _committed;

  @override
  Future<int> beginAccessTokenAttempt(String ownerId) async {
    _latest += 1;
    return _latest;
  }

  @override
  Future<bool> savePendingAccessTokenForOwner({
    required String token,
    required String ownerId,
    required int attemptVersion,
  }) async {
    if (attemptVersion != _latest) return false;
    _pending = token;
    _owner = ownerId;
    _version = attemptVersion;
    return true;
  }

  @override
  Future<bool> commitAccessTokenForOwner(
    String ownerId, {
    required int attemptVersion,
  }) async {
    if (_owner != ownerId || _version != attemptVersion) return false;
    _committed = _pending;
    _pending = null;
    return true;
  }

  @override
  Future<bool> clearAccessTokenForOwner(
    String ownerId, {
    required int attemptVersion,
  }) async {
    if (_owner != ownerId || _version != attemptVersion) return false;
    _pending = null;
    _owner = null;
    _version = null;
    return true;
  }

  @override
  Future<bool> clearPendingAccessToken() async {
    final hadPending = _pending != null;
    _pending = null;
    _owner = null;
    _version = null;
    return hadPending;
  }

  @override
  Future<void> clearAccessToken() async => _committed = null;

  @override
  Future<String?> readAccessToken() async => _committed;

  @override
  Future<void> saveAccessToken(String token) async => _committed = token;
}
