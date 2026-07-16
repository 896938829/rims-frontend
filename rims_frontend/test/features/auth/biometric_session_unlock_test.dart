import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/security/local_authenticator.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:rims_frontend/features/auth/data/models/auth_models.dart';
import 'package:rims_frontend/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:rims_frontend/features/auth/domain/entities/app_user.dart';
import 'package:rims_frontend/features/auth/domain/entities/auth_session.dart';
import 'package:rims_frontend/features/auth/domain/repositories/local_unlock_repository.dart';
import 'package:rims_frontend/features/auth/presentation/view_models/auth_session_controller.dart';

void main() {
  test(
    'biometric unlock restores only the released existing credential',
    () async {
      final credential = _credential();
      final vault = _Vault(credential);
      final coordinator = LocalUnlockCoordinator(
        authenticator: _Authenticator(),
        vault: vault,
        now: () => DateTime.utc(2026, 7, 16, 12),
      );
      final repository = _UnlockedRepository();
      final controller = AuthSessionController();

      final result = await controller.unlockWithBiometrics(
        coordinator: coordinator,
        repository: repository,
      );

      expect(result.isSuccess, isTrue);
      expect(repository.received, same(credential));
      expect(repository.received?.generation, 2);
      expect(repository.received?.refreshExpiresAt, DateTime.utc(2026, 7, 20));
      expect(controller.isAuthenticated, isTrue);
    },
  );

  test(
    'explicit server rejection quarantines exact credential without logout',
    () async {
      final credential = _credential();
      final repository = _RejectingUnlockedRepository();
      final controller = AuthSessionController();
      final result = await controller.unlockWithBiometrics(
        coordinator: LocalUnlockCoordinator(
          authenticator: _Authenticator(),
          vault: _Vault(credential),
          now: () => DateTime.utc(2026, 7, 16, 12),
        ),
        repository: repository,
      );

      expect(result.isFailure, isTrue);
      expect(repository.quarantineCalls, 1);
      expect(repository.quarantined, same(credential));
      expect(controller.isAuthenticated, isFalse);
    },
  );

  test(
    'repository validates with explicit token without rotating or storing',
    () async {
      final remote = _ExplicitRemote();
      final storage = _TokenStorage();
      final repository =
          AuthRepositoryImpl(
                remoteDataSource: remote,
                secureStorage: storage,
                now: () => DateTime.utc(2026, 7, 16, 12),
              )
              as UnlockedCredentialSessionRepository;

      final result = await repository.restoreUnlockedCredential(_credential());

      expect(result.isSuccess, isTrue);
      expect(remote.currentUserToken, 'access-token');
      expect(remote.warehouseToken, 'access-token');
      expect(storage.writeCalls, 0);
    },
  );
}

final class _RejectingUnlockedRepository
    implements UnlockedCredentialSessionRepository {
  int quarantineCalls = 0;
  DeviceCredential? quarantined;

  @override
  Future<Result<AuthSession>> restoreUnlockedCredential(
    DeviceCredential credential,
  ) async => const FailureResult(AuthorizationFailure(message: '当前会话已撤销'));

  @override
  Future<Result<void>> quarantineRejectedCredential(
    DeviceCredential credential,
  ) async {
    quarantineCalls += 1;
    quarantined = credential;
    return const Success(null);
  }
}

final class _ExplicitRemote
    implements AuthRemoteDataSource, ExplicitCredentialAuthRemoteDataSource {
  String? currentUserToken;
  String? warehouseToken;

  @override
  Future<Result<AppUserModel>> loadCurrentUserWithAccessToken(
    String accessToken,
  ) async {
    currentUserToken = accessToken;
    return const Success(
      AppUserModel(
        id: 7,
        username: 'alice',
        realName: 'Alice',
        roleCode: 'operator',
        roleName: 'Operator',
      ),
    );
  }

  @override
  Future<Result<List<WarehouseModel>>> loadWarehouses({
    String? accessToken,
  }) async {
    warehouseToken = accessToken;
    return const Success([]);
  }

  @override
  Future<Result<AppUserModel>> loadCurrentUser() => throw UnimplementedError();

  @override
  Future<Result<LoginResponseModel>> login({
    required String username,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<Result<WarehouseModel?>> switchCurrentWarehouse(int warehouseId) =>
      throw UnimplementedError();
}

final class _TokenStorage implements TokenStorage {
  int writeCalls = 0;

  @override
  Future<void> clearAccessToken() async {
    writeCalls += 1;
  }

  @override
  Future<String?> readAccessToken() async => null;

  @override
  Future<void> saveAccessToken(String token) async {
    writeCalls += 1;
  }
}

final class _UnlockedRepository implements UnlockedCredentialSessionRepository {
  DeviceCredential? received;

  @override
  Future<Result<void>> quarantineRejectedCredential(
    DeviceCredential credential,
  ) async => const Success(null);

  @override
  Future<Result<AuthSession>> restoreUnlockedCredential(
    DeviceCredential credential,
  ) async {
    received = credential;
    return const Success(
      AuthSession(
        accessToken: 'access-token',
        user: AppUser(
          id: 7,
          username: 'alice',
          realName: 'Alice',
          roleCode: 'operator',
          roleName: 'Operator',
        ),
        currentWarehouse: null,
        warehouses: [],
      ),
    );
  }
}

final class _Authenticator implements LocalAuthenticator {
  @override
  Future<LocalAuthenticationResult> authenticate() async =>
      LocalAuthenticationResult.success;
}

final class _Vault implements BiometricCredentialVault {
  _Vault(this.credential);
  final DeviceCredential credential;

  @override
  Future<BiometricCredentialInspection> inspectForBiometricUnlock(
    DateTime now,
  ) async => BiometricCredentialInspection(
    availability: BiometricCredentialAvailability.available,
    metadata: LockedCredentialMetadata.fromCredential(credential),
  );

  @override
  Future<DeviceCredential?> releaseAfterBiometric({
    required LockedCredentialMetadata expected,
    required DateTime now,
  }) async => credential;

  @override
  Future<bool> setBiometricPolicy({
    required LockedCredentialMetadata expected,
    required BiometricCredentialPolicy policy,
  }) async => false;
}

DeviceCredential _credential() => DeviceCredential(
  accessToken: 'access-token',
  refreshToken: 'refresh-token',
  accountId: '7',
  sessionId: 'session-7',
  accessExpiresAt: DateTime.utc(2026, 7, 16, 12, 5),
  refreshExpiresAt: DateTime.utc(2026, 7, 20),
  tokenVersion: 4,
  generation: 2,
  biometricPolicy: BiometricCredentialPolicy.requireUnlock,
);
