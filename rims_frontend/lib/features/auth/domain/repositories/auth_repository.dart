import '../../../../core/result/result.dart';
import '../entities/auth_session.dart';
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

abstract interface class AuthTokenTransactionRepository {
  Future<Result<AuthSession>> loginWithTokenOwner({
    required String username,
    required String password,
    required String ownerId,
  });
}

abstract interface class AuthRepository {
  Future<Result<AuthSession?>> restoreSession();

  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse);

  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  });

  Future<void> logout();
}
