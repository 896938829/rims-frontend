import '../../../../core/result/result.dart';
import '../../../../core/storage/app_secure_storage.dart';
import '../entities/auth_session.dart';
import '../entities/device_session.dart';
import '../entities/warehouse.dart';

enum AuthSessionSource { network, cache }

abstract interface class AuthSessionRestoreMetadata {
  AuthSessionSource? get lastRestoreSource;

  DateTime? get lastRestoreFetchedAt;

  DateTime? get lastRestoreExpiresAt;
}

abstract interface class AuthCredentialInvalidator {
  Future<void> expireCredentials();
}

abstract interface class OwnerBoundCredentialQuarantine {
  Future<DeviceCredential?> captureCredentialForQuarantine();

  Future<bool> quarantineCredential(DeviceCredential expected);
}

abstract interface class AbandonedLoginCredentialCleaner {
  Future<Result<void>> cleanupAbandonedLogin(AuthSession rejectedSession);
}

abstract interface class SessionCredentialRepository {
  Future<Result<DeviceCredential>> refreshCredential(DeviceCredential current);
}

abstract interface class AuthSessionTransaction {
  AuthSession get session;

  Future<Result<void>> commit();

  Future<Result<void>> abort();
}

abstract interface class OwnershipPreparedAuthSessionTransaction {
  bool get hasPreparedReauthentication;

  Future<Result<void>> finalizeReauthentication();
}

abstract interface class TransactionalAuthRepository {
  Future<Result<AuthSessionTransaction>> prepareLogin({
    required String username,
    required String password,
  });
}

abstract interface class ProvisionalTransactionalAuthRepository
    implements TransactionalAuthRepository {
  Object get tokenTransactionStorageIdentity;
}

abstract interface class ProvisionalAuthSessionTransaction
    implements AuthSessionTransaction {
  String get transactionOwnerId;

  int get transactionAttemptVersion;
}

abstract interface class AuthRepository {
  Future<Result<AuthSession?>> restoreSession();

  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse);

  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  });

  Future<Result<List<DeviceSession>>> listDeviceSessions();

  Future<Result<void>> revokeDeviceSession(String sessionId);

  Future<Result<int>> revokeOtherDeviceSessions();

  Future<Result<int>> revokeAllDeviceSessions();

  Future<void> logout();
}
