import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/storage/app_secure_storage.dart';
import '../../domain/entities/app_user.dart';
import '../../domain/entities/auth_session.dart';
import '../../domain/entities/warehouse.dart';
import '../../domain/repositories/auth_repository.dart';
import '../datasources/auth_remote_datasource.dart';
import '../models/auth_models.dart';

final class AuthRepositoryImpl
    implements AuthRepository, AuthCredentialInvalidator {
  const AuthRepositoryImpl({
    required this.remoteDataSource,
    required this.secureStorage,
  });

  final AuthRemoteDataSource remoteDataSource;
  final TokenStorage secureStorage;

  @override
  Future<Result<AuthSession?>> restoreSession() async {
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

        if (sessionResult case FailureResult<AuthSession>(:final failure)
            when failure is AuthenticationFailure ||
                failure is AuthorizationFailure) {
          await secureStorage.clearAccessToken();
        }

        return sessionResult;
      },
      failure: (failure) async {
        if (failure is AuthenticationFailure ||
            failure is AuthorizationFailure) {
          await secureStorage.clearAccessToken();
        }
        return FailureResult<AuthSession?>(failure);
      },
    );
  }

  @override
  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  }) async {
    final loginResult = await remoteDataSource.login(
      username: username,
      password: password,
    );

    return _sessionFromLoginResult(loginResult);
  }

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) async {
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
  }

  Future<Result<AuthSession>> _sessionFromLoginResult(
    Result<LoginResponseModel> loginResult,
  ) async {
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

        await secureStorage.saveAccessToken(token);

        return _sessionFromUserAndToken(
          token: token,
          user: user,
          clearTokenOnAnyFailure: true,
        );
      },
      failure: (failure) async => FailureResult<AuthSession>(failure),
    );
  }

  Future<Result<AuthSession>> _sessionFromUserAndToken({
    required String token,
    required AppUser user,
    required bool clearTokenOnAnyFailure,
  }) async {
    final warehouseResult = await remoteDataSource.loadWarehouses();
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
        if (clearTokenOnAnyFailure ||
            failure is AuthenticationFailure ||
            failure is AuthorizationFailure) {
          await secureStorage.clearAccessToken();
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
