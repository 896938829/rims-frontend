import '../../../../core/result/result.dart';
import '../../../../core/storage/app_secure_storage.dart';
import '../../domain/entities/auth_session.dart';
import '../../domain/entities/warehouse.dart';
import '../../domain/repositories/auth_repository.dart';
import '../datasources/auth_remote_datasource.dart';

final class AuthRepositoryImpl implements AuthRepository {
  const AuthRepositoryImpl({
    required this.remoteDataSource,
    required this.secureStorage,
  });

  final AuthRemoteDataSource remoteDataSource;
  final AppSecureStorage secureStorage;

  @override
  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  }) async {
    final loginResult = await remoteDataSource.login(
      username: username,
      password: password,
    );

    return loginResult.when(
      success: (login) async {
        await secureStorage.saveAccessToken(login.token);

        final warehouseResult = await remoteDataSource.loadWarehouses();
        return warehouseResult.when(
          success: (warehouseModels) {
            final warehouses = warehouseModels
                .map((warehouse) => warehouse.toEntity())
                .toList(growable: false);
            final currentWarehouse = _selectCurrentWarehouse(warehouses);

            return Success<AuthSession>(
              AuthSession(
                accessToken: login.token,
                user: login.user.toEntity(),
                currentWarehouse: currentWarehouse,
                warehouses: warehouses,
              ),
            );
          },
          failure: (failure) async {
            await secureStorage.clearAccessToken();
            return FailureResult<AuthSession>(failure);
          },
        );
      },
      failure: (failure) async => FailureResult<AuthSession>(failure),
    );
  }

  @override
  Future<void> logout() {
    return secureStorage.clearAccessToken();
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
}
