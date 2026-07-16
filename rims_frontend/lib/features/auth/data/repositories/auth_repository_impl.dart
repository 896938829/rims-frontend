import 'dart:async';

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

class AuthRepositoryImpl
    implements
        AuthRepository,
        AuthCredentialInvalidator,
        OwnerBoundCredentialQuarantine,
        AbandonedLoginCredentialCleaner,
        SessionCredentialRepository {
  factory AuthRepositoryImpl({
    required AuthRemoteDataSource remoteDataSource,
    required TokenStorage secureStorage,
    String Function() tokenOwnerFactory = _newTokenOwnerId,
    int Function()? authEpochReader,
  }) {
    if (secureStorage is AuthTokenTransactionStorage) {
      return _TransactionalAuthRepositoryImpl(
        remoteDataSource: remoteDataSource,
        secureStorage: secureStorage,
        tokenOwnerFactory: tokenOwnerFactory,
        authEpochReader: authEpochReader,
      );
    }
    return AuthRepositoryImpl._(
      remoteDataSource: remoteDataSource,
      secureStorage: secureStorage,
      tokenOwnerFactory: tokenOwnerFactory,
      authEpochReader: authEpochReader,
    );
  }

  AuthRepositoryImpl._({
    required this.remoteDataSource,
    required this.secureStorage,
    required this.tokenOwnerFactory,
    this.authEpochReader,
  });

  final AuthRemoteDataSource remoteDataSource;
  final TokenStorage secureStorage;
  final String Function() tokenOwnerFactory;
  final int Function()? authEpochReader;
  final Expando<_PlainAuthSessionTransaction> _plainTransactions = Expando();

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
    _PlainTokenAttempt? plainAttempt;
    try {
      await _clearAbandonedPendingToken();
      if (secureStorage case final AuthTokenTransactionStorage transaction) {
        attemptVersion = await transaction.beginAccessTokenAttempt(ownerId);
      } else {
        plainAttempt = await _plainTokenAuthority(secureStorage).begin(ownerId);
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
        Success<AuthSession>(data: final session) => Success(() {
          if (secureStorage is AuthTokenTransactionStorage &&
              attemptVersion != null) {
            return _StoredAuthSessionTransaction(
              session: session,
              storage: secureStorage as AuthTokenTransactionStorage,
              ownerId: ownerId,
              attemptVersion: attemptVersion,
            );
          }
          final transaction = _PlainAuthSessionTransaction(
            session: session,
            storage: secureStorage,
            authority: _plainTokenAuthority(secureStorage),
            attempt: plainAttempt!,
          );
          _plainTransactions[session] = transaction;
          return transaction;
        }()),
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
  Future<DeviceCredential?> captureCredentialForQuarantine() async {
    if (secureStorage case final DeviceCredentialStorage storage) {
      return storage.readDeviceCredential();
    }
    return null;
  }

  @override
  Future<bool> quarantineCredential(DeviceCredential expected) async {
    if (secureStorage case final DeviceCredentialStorage storage) {
      final active = await storage.readDeviceCredential();
      if (!_sameFullCredential(active, expected)) return active == null;
      if (secureStorage case final ConditionalTokenStorage conditional) {
        return conditional.clearAccessTokenIfMatches(expected.accessToken);
      }
      return storage.clearDeviceCredentialIfMatches(
        accountId: expected.accountId,
        sessionId: expected.sessionId,
        generation: expected.generation,
      );
    }
    if (secureStorage case final ConditionalTokenStorage conditional) {
      return conditional.clearAccessTokenIfMatches(expected.accessToken);
    }
    return false;
  }

  @override
  Future<Result<void>> cleanupAbandonedLogin(
    AuthSession rejectedSession,
  ) async {
    final transaction = _plainTransactions[rejectedSession];
    if (transaction == null) {
      return const FailureResult(
        RevocationCleanupFailure(
          message: 'Unable to identify the abandoned credential owner.',
        ),
      );
    }
    final result = await transaction.abort();
    return switch (result) {
      Success<void>() => const Success(null),
      FailureResult<void>(failure: final failure) => FailureResult(
        RevocationCleanupFailure(
          message: 'Unable to quarantine the abandoned credential.',
          cause: sanitizeTransportCause(failure),
        ),
      ),
    };
  }

  @override
  Future<void> expireCredentials() async {
    final expected = await captureCredentialForQuarantine();
    if (expected != null) {
      if (await quarantineCredential(expected)) return;
      throw const RevocationCleanupFailure(
        message: 'Unable to quarantine the owner-bound device credential.',
      );
    }

    final accessToken = await secureStorage.readAccessToken();
    if (accessToken == null || accessToken.isEmpty) return;
    if (secureStorage case final ConditionalTokenStorage conditional) {
      if (await conditional.clearAccessTokenIfMatches(accessToken)) return;
    }
    throw const RevocationCleanupFailure(
      message: 'Unable to quarantine the captured access token.',
    );
  }

  bool _sameCredential(DeviceCredential? active, DeviceCredential expected) =>
      active?.accountId == expected.accountId &&
      active?.sessionId == expected.sessionId &&
      active?.generation == expected.generation;

  bool _sameIdentity(DeviceCredential left, DeviceCredential right) =>
      left.accountId == right.accountId && left.sessionId == right.sessionId;

  bool _sameFullCredential(
    DeviceCredential? active,
    DeviceCredential expected,
  ) =>
      active?.accountId == expected.accountId &&
      active?.sessionId == expected.sessionId &&
      active?.generation == expected.generation &&
      active?.accessToken == expected.accessToken;

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

final class _TransactionalAuthRepositoryImpl extends AuthRepositoryImpl
    implements
        TransactionalAuthRepository,
        ProvisionalTransactionalAuthRepository {
  _TransactionalAuthRepositoryImpl({
    required super.remoteDataSource,
    required super.secureStorage,
    required super.tokenOwnerFactory,
    super.authEpochReader,
  }) : super._();
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
      final cleared = await storage.clearAccessTokenForOwner(
        ownerId,
        attemptVersion: attemptVersion,
      );
      if (!cleared) return const Success(null);
      return const Success(null);
    } on Object catch (error) {
      return FailureResult(
        RevocationCleanupFailure(
          message: 'Unable to quarantine the authenticated credential.',
          cause: sanitizeTransportCause(error),
        ),
      );
    }
  }
}

final Expando<_PlainTokenAuthority> _plainTokenAuthorities = Expando();

_PlainTokenAuthority _plainTokenAuthority(TokenStorage storage) =>
    _plainTokenAuthorities[storage] ??= _PlainTokenAuthority();

final class _PlainTokenAttempt {
  const _PlainTokenAttempt(this.ownerId, this.version);

  final String ownerId;
  final int version;
}

final class _PlainTokenAuthority {
  Future<void> _tail = Future<void>.value();
  int _latestVersion = 0;
  String? _committedOwnerId;
  int? _committedVersion;

  Future<T> _run<T>(Future<T> Function() operation) {
    final previous = _tail;
    final completed = Completer<void>();
    _tail = completed.future;
    return previous.then((_) => operation()).whenComplete(completed.complete);
  }

  Future<_PlainTokenAttempt> begin(String ownerId) => _run(() async {
    _latestVersion += 1;
    return _PlainTokenAttempt(ownerId, _latestVersion);
  });

  Future<bool> commit(
    TokenStorage storage,
    _PlainTokenAttempt attempt,
    String token,
  ) => _run(() async {
    if (attempt.version != _latestVersion) return false;
    await storage.saveAccessToken(token);
    _committedOwnerId = attempt.ownerId;
    _committedVersion = attempt.version;
    return true;
  });

  Future<bool> abort(
    TokenStorage storage,
    _PlainTokenAttempt attempt,
    String token,
  ) => _run(() async {
    if (_committedOwnerId != attempt.ownerId ||
        _committedVersion != attempt.version) {
      return true;
    }
    if (await storage.readAccessToken() != token) return true;
    await storage.clearAccessToken();
    if (await storage.readAccessToken() != null) return false;
    _committedOwnerId = null;
    _committedVersion = null;
    return true;
  });
}

final class _PlainAuthSessionTransaction implements AuthSessionTransaction {
  const _PlainAuthSessionTransaction({
    required this.session,
    required this.storage,
    required this.authority,
    required this.attempt,
  });

  @override
  final AuthSession session;
  final TokenStorage storage;
  final _PlainTokenAuthority authority;
  final _PlainTokenAttempt attempt;

  @override
  Future<Result<void>> abort() async {
    try {
      final cleared = await authority.abort(
        storage,
        attempt,
        session.accessToken,
      );
      return cleared
          ? const Success(null)
          : const FailureResult(
              RevocationCleanupFailure(
                message: 'Unable to quarantine the abandoned credential.',
              ),
            );
    } on Object catch (error) {
      return FailureResult(
        RevocationCleanupFailure(
          message: 'Unable to quarantine the abandoned credential.',
          cause: sanitizeTransportCause(error),
        ),
      );
    }
  }

  @override
  Future<Result<void>> commit() async {
    try {
      final committed = await authority.commit(
        storage,
        attempt,
        session.accessToken,
      );
      return committed
          ? const Success(null)
          : const FailureResult(
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
}
