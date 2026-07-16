import '../../../../core/network/sanitized_transport_cause.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/security/local_authenticator.dart';
import '../../../../core/storage/app_secure_storage.dart';
import '../../domain/repositories/local_unlock_repository.dart';

final class BiometricSettingsRepositoryImpl
    implements BiometricSettingsRepository {
  const BiometricSettingsRepositoryImpl({
    required this.credentialStorage,
    required this.vault,
    required this.authenticator,
    required this.now,
  });

  final DeviceCredentialStorage credentialStorage;
  final BiometricCredentialVault vault;
  final LocalAuthenticator authenticator;
  final DateTime Function() now;

  @override
  Future<Result<bool>> isEnabled() async {
    try {
      final credential = await credentialStorage.readDeviceCredential();
      final currentTime = now().toUtc();
      if (credential == null ||
          !credential.accessExpiresAt.isAfter(currentTime) ||
          !credential.refreshExpiresAt.isAfter(currentTime)) {
        return const FailureResult(AuthenticationFailure(message: '当前登录凭据不可用'));
      }
      return Success(
        credential.biometricPolicy == BiometricCredentialPolicy.requireUnlock,
      );
    } on Object catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: '无法读取本机解锁设置',
          cause: sanitizeTransportCause(error),
        ),
      );
    }
  }

  @override
  Future<Result<void>> setEnabled(bool value) async {
    try {
      final credential = await credentialStorage.readDeviceCredential();
      final currentTime = now().toUtc();
      if (credential == null ||
          !credential.accessExpiresAt.isAfter(currentTime) ||
          !credential.refreshExpiresAt.isAfter(currentTime)) {
        return const FailureResult(AuthenticationFailure(message: '当前登录凭据不可用'));
      }
      if (value) {
        final authentication = await authenticator.authenticate();
        if (authentication != LocalAuthenticationResult.success) {
          return const FailureResult(
            StateFailure(message: '未完成生物识别验证，未启用本机解锁'),
          );
        }
      }
      final updated = await vault.setBiometricPolicy(
        expected: LockedCredentialMetadata.fromCredential(credential),
        policy: value
            ? BiometricCredentialPolicy.requireUnlock
            : BiometricCredentialPolicy.disabled,
      );
      return updated
          ? const Success(null)
          : const FailureResult(StateFailure(message: '本机登录凭据已变化，请重试'));
    } on Object catch (error) {
      return FailureResult(
        LocalStorageFailure(
          message: '无法更新本机解锁设置',
          cause: sanitizeTransportCause(error),
        ),
      );
    }
  }
}
