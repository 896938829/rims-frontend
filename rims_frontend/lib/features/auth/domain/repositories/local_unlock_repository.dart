import '../../../../core/result/result.dart';
import '../../../../core/storage/app_secure_storage.dart';
import '../entities/auth_session.dart';

abstract interface class BiometricSettingsRepository {
  Future<Result<bool>> isEnabled();

  Future<Result<void>> setEnabled(bool value);
}

abstract interface class UnlockedCredentialSessionRepository {
  Future<Result<AuthSession>> restoreUnlockedCredential(
    DeviceCredential credential,
  );

  Future<Result<void>> quarantineRejectedCredential(
    DeviceCredential credential,
  );
}
