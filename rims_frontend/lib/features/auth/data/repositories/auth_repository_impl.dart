import '../../../../core/network/sanitized_transport_cause.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/storage/app_secure_storage.dart';
import 'package:uuid/uuid.dart';
import '../../domain/entities/app_user.dart';
import '../../domain/entities/auth_session.dart';
import '../../domain/entities/device_session.dart';
import '../../domain/entities/warehouse.dart';
import '../../domain/repositories/auth_repository.dart';
import '../datasources/auth_remote_datasource.dart';
import '../models/auth_models.dart';

final class AuthRepositoryImpl
    implements
        AuthRepository,
        AuthCredentialInvalidator,
        TransactionalAuthRepository,
        ProvisionalTransactionalAuthRepository,
        SessionCredentialRepository {
  const AuthRepositoryImpl({
    required this.remoteDataSource,
    required this.secureStorage,
    this.tokenOwnerFactory = _newTokenOwnerId,
    this.authEpochReader,
  });

  final AuthRemoteDataSource remoteDataSource;
  final TokenStorage secureStorage;
  final String Function() tokenOwnerFactory;
  final int Function()? authEpochReader;

  @override
  Object get tokenTransactionStorageIdentity => secureStorage;

  @override
  Future<Result<AuthSession?>> restoreSession() async {
    try {
      await _clearAbandonedPendingToken();
      final token = await secureStorage.readAccessToken();
      if (token == null || token.isEmpty) {
        return const Success<AuthSession?>(null);
      }

      final userResult = await remoteDataSource.loadCurrentUser();
      return userResult.when(
        success: (user) async {
          final currentUser = user.toEntity();
          final userFailure = _validateUser(currentUser);
          if (userFailure != null) {
            await secureStorage.clearAccessToken();
            return FailureResult<AuthSession?>(userFailure);
          }

          final sessionResult = await _sessionFromUserAndToken(
            token: token,
            user: currentUser,
            clearTokenOnAnyFailure: false,
          );

          return sessionResult;
        },
        failure: (failure) async => FailureResult<AuthSession?>(failure),
      );
    } on Object catch (error) {
      return _localStorageFailure(
        'Unable to read or update the stored credential.',
        error,
      );
    }
  }

  @override
  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  }) async {
    final prepared = await prepareLogin(username: username, password: password);
    return switch (prepared) {
      Success<AuthSessionTransaction>(data: final transaction) =>
        _commitRawLogin(transaction),
      FailureResult<AuthSessionTransaction>(failure: final failure) =>
        FailureResult(failure),
    };
  }

  @override
  Future<Result<AuthSessionTransaction>> prepareLogin({
    required String username,
    required String password,
  }) => _prepareLoginTransaction(
    username: username,
    password: password,
    ownerId: tokenOwnerFactory(),
  );

  Future<Result<AuthSessionTransaction>> _prepareLoginTransaction({
    required String username,
    required String password,
    required String ownerId,
  }) async {
    int? attemptVersion;
    try {
      await _clearAbandonedPendingToken();
      if (secureStorage case final AuthTokenTransactionStorage transaction) {
        attemptVersion = await transaction.beginAccessTokenAttempt(ownerId);
      }
      final loginResult = await remoteDataSource.login(
        username: username,
        password: password,
      );
      final sessionResult = await _sessionFromLoginResult(
        loginResult,
        ownerId: ownerId,
        attemptVersion: attemptVersion,
      );
      return switch (sessionResult) {
        Success<AuthSession>(data: final session) => Success(
          secureStorage is AuthTokenTransactionStorage && attemptVersion != null
              ? _StoredAuthSessionTransaction(
                  session: session,
                  storage: secureStorage as AuthTokenTransactionStorage,
                  ownerId: ownerId,
                  attemptVersion: attemptVersion,
                )
              : _CommittedAuthSessionTransaction(session),
        ),
        FailureResult<AuthSession>(failure: final failure) => FailureResult(
          failure,
        ),
      };
    } on Object catch (error) {
      try {
        await _clearLoginToken(
          token: '',
          ownerId: ownerId,
          attemptVersion: attemptVersion,
        );
      } on Object {
        // A failed pending rollback remains unreadable by TokenStorage.
      }
      return _localStorageFailure(
        'Unable to complete the credential transaction.',
        error,
      );
    }
  }

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) async {
    try {
      final switchResult = await remoteDataSource.switchCurrentWarehouse(
        warehouse.id,
      );

      return switchResult.when(
        success: (warehouseModel) {
          if (warehouseModel == null) {
            return Success<Warehouse>(warehouse);
          }

          return Success<Warehouse>(
            Warehouse(
              id: warehouseModel.id,
              code: warehouseModel.code,
              name: warehouseModel.name,
              isDefault: warehouse.isDefault,
            ),
          );
        },
        failure: FailureResult<Warehouse>.new,
      );
    } on Object catch (error) {
      return _localStorageFailure(
        'Unable to complete the warehouse session update.',
        error,
      );
    }
  }

  DeviceSessionsRemoteDataSource? get _deviceSessionsRemote =>
      remoteDataSource is DeviceSessionsRemoteDataSource
      ? remoteDataSource as DeviceSessionsRemoteDataSource
      : null;

  @override
  Future<Result<List<DeviceSession>>> listDeviceSessions() async {
    final remote = _deviceSessionsRemote;
    if (remote == null) {
      return const FailureResult(
        StateFailure(message: 'Device session management is unavailable.'),
      );
    }
    try {
      final result = await remote.listDeviceSessions();
      return result.when(
        success: (sessions) => Success(
          sessions.map((session) => session.toEntity()).toList(growable: false),
        ),
        failure: FailureResult<List<DeviceSession>>.new,
      );
    } on Object catch (error) {
      return _deviceSessionFailure(error);
    }
  }

  @override
  Future<Result<void>> revokeDeviceSession(String sessionId) async {
    final remote = _deviceSessionsRemote;
    if (remote == null) {
      return const FailureResult(
        StateFailure(message: 'Device session management is unavailable.'),
      );
    }
    try {
      return await remote.revokeDeviceSession(sessionId);
    } on Object catch (error) {
      return _deviceSessionFailure(error);
    }
  }

  @override
  Future<Result<int>> revokeOtherDeviceSessions() async {
    final remote = _deviceSessionsRemote;
    if (remote == null) {
      return const FailureResult(
        StateFailure(message: 'Device session management is unavailable.'),
      );
    }
    try {
      return await remote.revokeOtherDeviceSessions();
    } on Object catch (error) {
      return _deviceSessionFailure(error);
    }
  }

  @override
  Future<Result<int>> revokeAllDeviceSessions() async {
    final remote = _deviceSessionsRemote;
    if (remote == null) {
      return const FailureResult(
        StateFailure(message: 'Device session management is unavailable.'),
      );
    }
    try {
      return await remote.revokeAllDeviceSessions();
    } on Object catch (error) {
      return _deviceSessionFailure(error);
    }
  }

  FailureResult<T> _deviceSessionFailure<T>(Object error) => FailureResult<T>(
    UnknownFailure(
      message: 'Unable to manage device sessions.',
      cause: sanitizeTransportCause(error),
    ),
  );

  Future<Result<AuthSession>> _sessionFromLoginResult(
    Result<LoginResponseModel> loginResult, {
    required String ownerId,
    required int? attemptVersion,
  }) async {
    return loginResult.when(
      success: (login) async {
        final token = login.accessToken.trim();
        if (token.isEmpty) {
          return const FailureResult<AuthSession>(
            UnknownFailure(message: '登录响应缺少 token'),
          );
        }

        final user = login.user.toEntity();
        final userFailure = _validateUser(user);
        if (userFailure != null) {
          return FailureResult<AuthSession>(userFailure);
        }

        try {
          if (secureStorage case final DeviceCredentialStorage deviceStorage
              when login.hasRotatingCredential) {
            final credential = _credentialFromLogin(
              login,
              generation: 1,
              biometricPolicy: BiometricCredentialPolicy.disabled,
            );
            final published = await deviceStorage
                .savePendingDeviceCredentialForOwner(
                  credential: credential,
                  ownerId: ownerId,
                  attemptVersion: attemptVersion!,
                );
            if (!published) {
              return const FailureResult<AuthSession>(
                LocalStorageFailure(
                  message: 'The authenticated credential was superseded.',
                ),
              );
            }
          } else if (secureStorage
              case final AuthTokenTransactionStorage owned) {
            final published = await owned.savePendingAccessTokenForOwner(
              token: token,
              ownerId: ownerId,
              attemptVersion: attemptVersion!,
            );
            if (!published) {
              return const FailureResult<AuthSession>(
                LocalStorageFailure(
                  message: 'The authenticated credential was superseded.',
                ),
              );
            }
          } else {
            await secureStorage.saveAccessToken(token);
          }
        } on Object catch (error) {
          return FailureResult<AuthSession>(
            LocalStorageFailure(
              message: 'Unable to store the authenticated credential.',
              cause: sanitizeTransportCause(error),
            ),
          );
        }

        final sessionResult = await _sessionFromUserAndToken(
          token: token,
          user: user,
          clearTokenOnAnyFailure: true,
          tokenOwnerId: ownerId,
          tokenAttemptVersion: attemptVersion,
        );
        return sessionResult;
      },
      failure: (failure) async => FailureResult<AuthSession>(failure),
    );
  }

  Future<Result<AuthSession>> _sessionFromUserAndToken({
    required String token,
    required AppUser user,
    required bool clearTokenOnAnyFailure,
    String? tokenOwnerId,
    int? tokenAttemptVersion,
  }) async {
    final warehouseResult = await remoteDataSource.loadWarehouses(
      accessToken: clearTokenOnAnyFailure ? token : null,
    );
    return warehouseResult.when(
      success: (warehouseModels) {
        final warehouses = warehouseModels
            .map((warehouse) => warehouse.toEntity())
            .toList(growable: false);
        final currentWarehouse = _selectCurrentWarehouse(warehouses);

        return Success<AuthSession>(
          AuthSession(
            accessToken: token,
            user: user,
            currentWarehouse: currentWarehouse,
            warehouses: warehouses,
          ),
        );
      },
      failure: (failure) async {
        if (clearTokenOnAnyFailure) {
          await _clearLoginToken(
            token: token,
            ownerId: tokenOwnerId,
            attemptVersion: tokenAttemptVersion,
          );
        }
        return FailureResult<AuthSession>(failure);
      },
    );
  }

  @override
  Future<void> logout() async {
    final expectedAuthEpoch = authEpochReader?.call();
    final rotatingRemote = remoteDataSource is RotatingAuthRemoteDataSource
        ? remoteDataSource as RotatingAuthRemoteDataSource
        : null;
    final deviceStorage = secureStorage is DeviceCredentialStorage
        ? secureStorage as DeviceCredentialStorage
        : null;
    final current = await deviceStorage?.readDeviceCredential();
    var remoteRevocationFailed = false;
    Object? markerError;
    if (rotatingRemote != null && current != null) {
      try {
        final result = await rotatingRemote.logout(
          accessToken: current.accessToken,
        );
        remoteRevocationFailed = result is FailureResult<void>;
      } on Object {
        remoteRevocationFailed = true;
      }
      if (remoteRevocationFailed) {
        if (secureStorage case final PendingRevocationStorage pending) {
          try {
            final active = await deviceStorage?.readDeviceCredential();
            if (_sameCredential(active, current)) {
              if (expectedAuthEpoch != null &&
                  pending is SessionPendingRevocationStorage) {
                await (pending as SessionPendingRevocationStorage)
                    .savePendingRevocationLease(
                      SessionRevocationLease(
                        accountId: current.accountId,
                        sessionId: current.sessionId,
                        generation: current.generation,
                        authEpoch: expectedAuthEpoch,
                      ),
                    );
              } else {
                await pending.savePendingRevocationAccountId(current.accountId);
              }
            }
          } on Object catch (error) {
            markerError = error;
          }
        }
      }
    }
    if (deviceStorage != null && current != null) {
      var cleared = await deviceStorage.clearDeviceCredentialIfMatches(
        accountId: current.accountId,
        sessionId: current.sessionId,
        generation: current.generation,
      );
      if (!cleared) {
        final latest = await deviceStorage.readDeviceCredential();
        final epochUnchanged =
            expectedAuthEpoch == null ||
            authEpochReader?.call() == expectedAuthEpoch;
        if (epochUnchanged &&
            latest != null &&
            _sameIdentity(latest, current) &&
            latest.generation > current.generation) {
          cleared = await deviceStorage.clearDeviceCredentialIfMatches(
            accountId: latest.accountId,
            sessionId: latest.sessionId,
            generation: latest.generation,
          );
        }
        if (!cleared) {
          final active = await deviceStorage.readDeviceCredential();
          if (epochUnchanged &&
              active != null &&
              _sameIdentity(active, current)) {
            throw const RevocationCleanupFailure(
              message: 'Unable to clear the logged out device credential.',
            );
          }
        }
      }
    } else {
      await secureStorage.clearAccessToken();
    }
    if (markerError != null) {
      throw RevocationCleanupFailure(
        message: 'Unable to retain pending credential revocation.',
        cause: sanitizeTransportCause(markerError),
      );
    }
  }

  @override
  Future<void> expireCredentials() => logout();

  bool _sameCredential(DeviceCredential? active, DeviceCredential expected) =>
      active?.accountId == expected.accountId &&
      active?.sessionId == expected.sessionId &&
      active?.generation == expected.generation;

  bool _sameIdentity(DeviceCredential left, DeviceCredential right) =>
      left.accountId == right.accountId && left.sessionId == right.sessionId;

  Future<void> _clearLoginToken({
    required String token,
    required String? ownerId,
    int? attemptVersion,
  }) async {
    if (ownerId != null && attemptVersion != null) {
      if (secureStorage case final AuthTokenTransactionStorage owned) {
        await owned.clearAccessTokenForOwner(
          ownerId,
          attemptVersion: attemptVersion,
        );
        return;
      }
    }
    if (secureStorage case final ConditionalTokenStorage conditional) {
      await conditional.clearAccessTokenIfMatches(token);
      return;
    }
    if (await secureStorage.readAccessToken() == token) {
      await secureStorage.clearAccessToken();
    }
  }

  Future<void> _clearAbandonedPendingToken() async {
    if (secureStorage case final AuthTokenTransactionStorage transaction) {
      await transaction.clearPendingAccessToken();
    }
  }

  @override
  Future<Result<DeviceCredential>> refreshCredential(
    DeviceCredential current,
  ) async {
    final remote = remoteDataSource is RotatingAuthRemoteDataSource
        ? remoteDataSource as RotatingAuthRemoteDataSource
        : null;
    if (remote == null) {
      return const FailureResult(
        AuthenticationFailure(message: 'Session refresh is unavailable.'),
      );
    }
    final result = await remote.refresh(refreshToken: current.refreshToken);
    return result.when(
      success: (login) {
        try {
          final next = _credentialFromLogin(
            login,
            generation: current.generation + 1,
            biometricPolicy: current.biometricPolicy,
          );
          if (next.accountId != current.accountId ||
              next.sessionId != current.sessionId) {
            return const FailureResult<DeviceCredential>(
              AuthenticationFailure(
                message: 'Rotated credential identity changed.',
              ),
            );
          }
          return Success(next);
        } on Object catch (error) {
          return FailureResult<DeviceCredential>(
            UnknownFailure(
              message: 'Invalid refresh response.',
              cause: sanitizeTransportCause(error),
            ),
          );
        }
      },
      failure: FailureResult<DeviceCredential>.new,
    );
  }

  FailureResult<T> _localStorageFailure<T>(String message, Object error) =>
      FailureResult<T>(
        LocalStorageFailure(
          message: message,
          cause: sanitizeTransportCause(error),
        ),
      );

  Future<Result<AuthSession>> _commitRawLogin(
    AuthSessionTransaction transaction,
  ) async {
    final committed = await transaction.commit();
    return switch (committed) {
      Success<void>() => Success(transaction.session),
      FailureResult<void>(failure: final failure) => () async {
        await transaction.abort();
        return FailureResult<AuthSession>(failure);
      }(),
    };
  }

  T? _firstWhereOrNull<T>(Iterable<T> values, bool Function(T value) test) {
    for (final value in values) {
      if (test(value)) {
        return value;
      }
    }

    return null;
  }

  Warehouse? _selectCurrentWarehouse(List<Warehouse> warehouses) {
    return _firstWhereOrNull(warehouses, (warehouse) => warehouse.isDefault) ??
        (warehouses.isNotEmpty ? warehouses.first : null);
  }

  Failure? _validateUser(AppUser user) {
    if (user.username.trim().isEmpty) {
      return const UnknownFailure(message: '用户信息缺少账号');
    }

    return null;
  }
}

DeviceCredential _credentialFromLogin(
  LoginResponseModel login, {
  required int generation,
  required BiometricCredentialPolicy biometricPolicy,
}) {
  if (!login.hasRotatingCredential) {
    throw const FormatException('Incomplete rotating credential response.');
  }
  final accountId = login.user.id.toString();
  if (login.user.id < 1 || accountId.isEmpty) {
    throw const FormatException('Invalid credential account identity.');
  }
  return DeviceCredential(
    accessToken: login.accessToken,
    refreshToken: login.refreshToken!,
    accountId: accountId,
    sessionId: login.session!.id,
    accessExpiresAt: login.accessExpiresAt!,
    refreshExpiresAt: login.refreshExpiresAt!,
    tokenVersion: login.tokenVersion!,
    generation: generation,
    biometricPolicy: biometricPolicy,
  );
}

String _newTokenOwnerId() => const Uuid().v4();

final class _StoredAuthSessionTransaction
    implements AuthSessionTransaction, ProvisionalAuthSessionTransaction {
  const _StoredAuthSessionTransaction({
    required this.session,
    required this.storage,
    required this.ownerId,
    required this.attemptVersion,
  });

  @override
  final AuthSession session;
  final AuthTokenTransactionStorage storage;
  final String ownerId;
  final int attemptVersion;

  @override
  String get transactionOwnerId => ownerId;

  @override
  int get transactionAttemptVersion => attemptVersion;

  @override
  Future<Result<void>> commit() async {
    try {
      final committed = await storage.commitAccessTokenForOwner(
        ownerId,
        attemptVersion: attemptVersion,
      );
      return committed
          ? const Success<void>(null)
          : const FailureResult<void>(
              LocalStorageFailure(
                message: 'The authenticated credential was superseded.',
              ),
            );
    } on Object catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to commit the authenticated credential.',
          cause: sanitizeTransportCause(error),
        ),
      );
    }
  }

  @override
  Future<Result<void>> abort() async {
    try {
      await storage.clearAccessTokenForOwner(
        ownerId,
        attemptVersion: attemptVersion,
      );
      return const Success(null);
    } on Object catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: 'Unable to abort the authenticated credential.',
          cause: sanitizeTransportCause(error),
        ),
      );
    }
  }
}

final class _CommittedAuthSessionTransaction implements AuthSessionTransaction {
  const _CommittedAuthSessionTransaction(this.session);

  @override
  final AuthSession session;

  @override
  Future<Result<void>> abort() async => const Success(null);

  @override
  Future<Result<void>> commit() async => const Success(null);
}
