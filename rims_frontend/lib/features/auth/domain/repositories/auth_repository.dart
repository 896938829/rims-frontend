import '../../../../core/result/result.dart';
import '../entities/auth_session.dart';
import '../entities/warehouse.dart';

abstract interface class AuthRepository {
  Future<Result<AuthSession?>> restoreSession();

  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse);

  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  });

  Future<void> logout();
}
