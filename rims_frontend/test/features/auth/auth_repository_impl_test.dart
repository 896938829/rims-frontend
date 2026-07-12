import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:rims_frontend/features/auth/data/models/auth_models.dart';
import 'package:rims_frontend/features/auth/data/repositories/auth_repository_impl.dart';

void main() {
  group('AuthRepositoryImpl', () {
    test(
      'restoreSession rebuilds session from stored token and backend data',
      () async {
        final storage = _FakeTokenStorage(accessToken: 'stored-token');
        final remoteDataSource = _FakeAuthRemoteDataSource(
          currentUserResult: const Success<AppUserModel>(
            AppUserModel(
              id: 7,
              username: 'alice',
              realName: 'Alice',
              roleCode: 'user',
              roleName: '普通用户',
            ),
          ),
          warehousesResult: const Success<List<WarehouseModel>>([
            WarehouseModel(id: 1, code: 'WH001', name: '默认仓库', isDefault: true),
          ]),
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        final result = await repository.restoreSession();

        final session = result.when(
          success: (session) => session,
          failure: (failure) => throw TestFailure(failure.message),
        );
        expect(session?.accessToken, 'stored-token');
        expect(session?.user.username, 'alice');
        expect(session?.currentWarehouse?.code, 'WH001');
        expect(remoteDataSource.loadCurrentUserCallCount, 1);
        expect(remoteDataSource.loadWarehousesCallCount, 1);
      },
    );

    test(
      'restoreSession skips backend calls when no token is stored',
      () async {
        final storage = _FakeTokenStorage();
        final remoteDataSource = _FakeAuthRemoteDataSource();
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        final result = await repository.restoreSession();

        final session = result.when(
          success: (session) => session,
          failure: (failure) => throw TestFailure(failure.message),
        );
        expect(session, isNull);
        expect(remoteDataSource.loadCurrentUserCallCount, 0);
        expect(remoteDataSource.loadWarehousesCallCount, 0);
      },
    );

    test('restoreSession clears stale token when backend rejects it', () async {
      final storage = _FakeTokenStorage(accessToken: 'expired-token');
      final remoteDataSource = _FakeAuthRemoteDataSource(
        currentUserResult: const FailureResult<AppUserModel>(
          AuthenticationFailure(message: '登录已过期', businessCode: 10001),
        ),
      );
      final repository = AuthRepositoryImpl(
        remoteDataSource: remoteDataSource,
        secureStorage: storage,
      );

      final result = await repository.restoreSession();

      expect(result.isFailure, isTrue);
      expect(storage.accessToken, isNull);
      expect(storage.clearCallCount, 1);
    });

    test(
      'restoreSession clears token when current user has no username',
      () async {
        final storage = _FakeTokenStorage(accessToken: 'stored-token');
        final remoteDataSource = _FakeAuthRemoteDataSource(
          currentUserResult: const Success<AppUserModel>(
            AppUserModel(
              id: 7,
              username: '',
              realName: 'Alice',
              roleCode: 'user',
              roleName: '普通用户',
            ),
          ),
          warehousesResult: const Success<List<WarehouseModel>>([
            WarehouseModel(id: 1, code: 'WH001', name: '默认仓库', isDefault: true),
          ]),
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        final result = await repository.restoreSession();

        expect(result.isFailure, isTrue);
        final failure = result.when(
          success: (_) => throw TestFailure('restore should fail'),
          failure: (failure) => failure,
        );
        expect(failure, isA<UnknownFailure>());
        expect(failure.message, '用户信息缺少账号');
        expect(storage.accessToken, isNull);
        expect(storage.clearCallCount, 1);
        expect(remoteDataSource.loadWarehousesCallCount, 0);
      },
    );

    test(
      'login rejects empty token without saving or loading warehouses',
      () async {
        final storage = _FakeTokenStorage();
        final remoteDataSource = _FakeAuthRemoteDataSource(
          loginResult: const Success<LoginResponseModel>(
            LoginResponseModel(
              token: '',
              user: AppUserModel(
                id: 7,
                username: 'alice',
                realName: 'Alice',
                roleCode: 'user',
                roleName: '普通用户',
              ),
            ),
          ),
          warehousesResult: const Success<List<WarehouseModel>>([
            WarehouseModel(id: 1, code: 'WH001', name: '默认仓库', isDefault: true),
          ]),
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        final result = await repository.login(
          username: 'alice',
          password: 'secret',
        );

        expect(result.isFailure, isTrue);
        final failure = result.when(
          success: (_) => throw TestFailure('login should fail'),
          failure: (failure) => failure,
        );
        expect(failure, isA<UnknownFailure>());
        expect(failure.message, '登录响应缺少 token');
        expect(storage.accessToken, isNull);
        expect(storage.saveCallCount, 0);
        expect(remoteDataSource.loadWarehousesCallCount, 0);
      },
    );

    test('login rejects user without username before saving token', () async {
      final storage = _FakeTokenStorage();
      final remoteDataSource = _FakeAuthRemoteDataSource(
        loginResult: const Success<LoginResponseModel>(
          LoginResponseModel(
            token: 'token-123',
            user: AppUserModel(
              id: 7,
              username: '',
              realName: 'Alice',
              roleCode: 'user',
              roleName: '普通用户',
            ),
          ),
        ),
        warehousesResult: const Success<List<WarehouseModel>>([
          WarehouseModel(id: 1, code: 'WH001', name: '默认仓库', isDefault: true),
        ]),
      );
      final repository = AuthRepositoryImpl(
        remoteDataSource: remoteDataSource,
        secureStorage: storage,
      );

      final result = await repository.login(
        username: 'alice',
        password: 'secret',
      );

      expect(result.isFailure, isTrue);
      final failure = result.when(
        success: (_) => throw TestFailure('login should fail'),
        failure: (failure) => failure,
      );
      expect(failure, isA<UnknownFailure>());
      expect(failure.message, '用户信息缺少账号');
      expect(storage.accessToken, isNull);
      expect(storage.saveCallCount, 0);
      expect(remoteDataSource.loadWarehousesCallCount, 0);
    });

    test(
      'switchCurrentWarehouse confirms target warehouse with backend',
      () async {
        final storage = _FakeTokenStorage(accessToken: 'active-token');
        final remoteDataSource = _FakeAuthRemoteDataSource(
          switchWarehouseResult: const Success<WarehouseModel>(
            WarehouseModel(id: 2, code: 'BJ', name: '北京仓', isDefault: false),
          ),
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        final result = await repository.switchCurrentWarehouse(
          const WarehouseModel(
            id: 2,
            code: 'BJ',
            name: '北京仓',
            isDefault: true,
          ).toEntity(),
        );

        final warehouse = result.when(
          success: (warehouse) => warehouse,
          failure: (failure) => throw TestFailure(failure.message),
        );
        expect(warehouse.id, 2);
        expect(warehouse.name, '北京仓');
        expect(warehouse.isDefault, isTrue);
        expect(remoteDataSource.lastSwitchWarehouseId, 2);
      },
    );

    test(
      'switchCurrentWarehouse keeps selected warehouse when backend returns no payload',
      () async {
        final storage = _FakeTokenStorage(accessToken: 'active-token');
        final remoteDataSource = _FakeAuthRemoteDataSource(
          switchWarehouseResult: const Success<WarehouseModel?>(null),
        );
        final repository = AuthRepositoryImpl(
          remoteDataSource: remoteDataSource,
          secureStorage: storage,
        );

        final result = await repository.switchCurrentWarehouse(
          const WarehouseModel(
            id: 3,
            code: 'GZ',
            name: '广州仓',
            isDefault: false,
          ).toEntity(),
        );

        final warehouse = result.when(
          success: (warehouse) => warehouse,
          failure: (failure) => throw TestFailure(failure.message),
        );
        expect(warehouse.id, 3);
        expect(warehouse.code, 'GZ');
        expect(warehouse.name, '广州仓');
        expect(warehouse.isDefault, isFalse);
        expect(remoteDataSource.lastSwitchWarehouseId, 3);
      },
    );
  });
}

final class _FakeTokenStorage implements TokenStorage {
  _FakeTokenStorage({this.accessToken});

  String? accessToken;
  int clearCallCount = 0;
  int saveCallCount = 0;

  @override
  Future<void> clearAccessToken() async {
    clearCallCount += 1;
    accessToken = null;
  }

  @override
  Future<String?> readAccessToken() async => accessToken;

  @override
  Future<void> saveAccessToken(String token) async {
    saveCallCount += 1;
    accessToken = token;
  }
}

final class _FakeAuthRemoteDataSource implements AuthRemoteDataSource {
  _FakeAuthRemoteDataSource({
    this.currentUserResult = const FailureResult<AppUserModel>(
      UnknownFailure(),
    ),
    this.warehousesResult = const FailureResult<List<WarehouseModel>>(
      UnknownFailure(),
    ),
    this.loginResult = const FailureResult<LoginResponseModel>(
      UnknownFailure(),
    ),
    this.switchWarehouseResult = const FailureResult<WarehouseModel?>(
      UnknownFailure(),
    ),
  });

  final Result<AppUserModel> currentUserResult;
  final Result<List<WarehouseModel>> warehousesResult;
  final Result<LoginResponseModel> loginResult;
  final Result<WarehouseModel?> switchWarehouseResult;
  int loadCurrentUserCallCount = 0;
  int loadWarehousesCallCount = 0;
  int? lastSwitchWarehouseId;

  @override
  Future<Result<AppUserModel>> loadCurrentUser() async {
    loadCurrentUserCallCount += 1;
    return currentUserResult;
  }

  @override
  Future<Result<List<WarehouseModel>>> loadWarehouses() async {
    loadWarehousesCallCount += 1;
    return warehousesResult;
  }

  @override
  Future<Result<WarehouseModel?>> switchCurrentWarehouse(
    int warehouseId,
  ) async {
    lastSwitchWarehouseId = warehouseId;
    return switchWarehouseResult;
  }

  @override
  Future<Result<LoginResponseModel>> login({
    required String username,
    required String password,
  }) async {
    return loginResult;
  }
}
