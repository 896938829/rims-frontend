import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/storage/app_secure_storage.dart';
import 'package:uuid/uuid.dart';
import '../../domain/entities/app_user.dart';
import '../../domain/entities/auth_session.dart';
import '../../domain/entities/warehouse.dart';
import '../../domain/repositories/auth_repository.dart';
import '../datasources/auth_remote_datasource.dart';
import '../models/auth_models.dart';

final class AuthRepositoryImpl
    implements
        AuthRepository,
        AuthCredentialInvalidator,
        AuthTokenTransactionRepository {
  const AuthRepositoryImpl({
    required this.remoteDataSource,
    required this.secureStorage,
    this.tokenOwnerFactory = _newTokenOwnerId,
  });

  final AuthRemoteDataSource remoteDataSource;
  final TokenStorage secureStorage;
  final String Function() tokenOwnerFactory;

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
  }) => _loginTransaction(
    username: username,
    password: password,
    ownerId: tokenOwnerFactory(),
    commitOnSuccess: true,
  );

  @override
  Future<Result<AuthSession>> loginWithTokenOwner({
    required String username,
    required String password,
    required String ownerId,
  }) => _loginTransaction(
    username: username,
    password: password,
    ownerId: ownerId,
    commitOnSuccess: false,
  );

  Future<Result<AuthSession>> _loginTransaction({
    required String username,
    required String password,
    required String ownerId,
    required bool commitOnSuccess,
  }) async {
    try {
      await _clearAbandonedPendingToken();
      final loginResult = await remoteDataSource.login(
        username: username,
        password: password,
      );
      return await _sessionFromLoginResult(
        loginResult,
        ownerId: ownerId,
        commitOnSuccess: commitOnSuccess,
      );
    } on Object catch (error) {
      try {
        await _clearLoginToken(token: '', ownerId: ownerId);
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

  Future<Result<AuthSession>> _sessionFromLoginResult(
    Result<LoginResponseModel> loginResult, {
    required String ownerId,
    required bool commitOnSuccess,
  }) async {
    return loginResult.when(
      success: (login) async {
        final token = login.token.trim();
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
          if (secureStorage case final AuthTokenTransactionStorage owned) {
            await owned.savePendingAccessTokenForOwner(
              token: token,
              ownerId: ownerId,
            );
          } else {
            await secureStorage.saveAccessToken(token);
          }
        } on Object catch (error) {
          return FailureResult<AuthSession>(
            LocalStorageFailure(
              message: 'Unable to store the authenticated credential.',
              cause: error,
            ),
          );
        }

        final sessionResult = await _sessionFromUserAndToken(
          token: token,
          user: user,
          clearTokenOnAnyFailure: true,
          tokenOwnerId: ownerId,
        );
        if (sessionResult is! Success<AuthSession> || !commitOnSuccess) {
          return sessionResult;
        }
        if (secureStorage case final AuthTokenTransactionStorage owned) {
          final committed = await owned.commitAccessTokenForOwner(ownerId);
          if (!committed) {
            return const FailureResult<AuthSession>(
              LocalStorageFailure(
                message: 'The authenticated credential was superseded.',
              ),
            );
          }
        }
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
          await _clearLoginToken(token: token, ownerId: tokenOwnerId);
        }
        return FailureResult<AuthSession>(failure);
      },
    );
  }

  @override
  Future<void> logout() {
    return secureStorage.clearAccessToken();
  }

  @override
  Future<void> expireCredentials() => logout();

  Future<void> _clearLoginToken({
    required String token,
    required String? ownerId,
  }) async {
    if (ownerId != null) {
      if (secureStorage case final AuthTokenTransactionStorage owned) {
        await owned.clearAccessTokenForOwner(ownerId);
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

  FailureResult<T> _localStorageFailure<T>(String message, Object error) =>
      FailureResult<T>(LocalStorageFailure(message: message, cause: error));

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

String _newTokenOwnerId() => const Uuid().v4();
