import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/security/local_authenticator.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/features/auth/data/repositories/biometric_settings_repository_impl.dart';

void main() {
  for (final result in [
    LocalAuthenticationResult.unsupported,
    LocalAuthenticationResult.failed,
    LocalAuthenticationResult.cancelled,
  ]) {
    test('$result cannot write requireUnlock policy', () async {
      final storage = _CredentialStorage(_credential());
      final vault = _PolicyVault();
      final repository = BiometricSettingsRepositoryImpl(
        credentialStorage: storage,
        vault: vault,
        authenticator: _Authenticator(result),
        now: () => DateTime.utc(2026, 7, 16, 12),
      );

      final changed = await repository.setEnabled(true);

      expect(changed.isFailure, isTrue);
      expect(vault.setCalls, 0);
    });
  }

  test(
    'OS biometric success is required immediately before policy write',
    () async {
      final storage = _CredentialStorage(_credential());
      final vault = _PolicyVault();
      final authenticator = _Authenticator(LocalAuthenticationResult.success);
      final repository = BiometricSettingsRepositoryImpl(
        credentialStorage: storage,
        vault: vault,
        authenticator: authenticator,
        now: () => DateTime.utc(2026, 7, 16, 12),
      );

      expect((await repository.setEnabled(true)).isSuccess, isTrue);
      expect(authenticator.calls, 1);
      expect(vault.setCalls, 1);
      expect(vault.policy, BiometricCredentialPolicy.requireUnlock);
    },
  );

  test('expired access credential cannot enable requireUnlock', () async {
    final storage = _CredentialStorage(
      _credential(accessExpiresAt: DateTime.utc(2026, 7, 16, 11, 59)),
    );
    final vault = _PolicyVault();
    final authenticator = _Authenticator(LocalAuthenticationResult.success);
    final repository = BiometricSettingsRepositoryImpl(
      credentialStorage: storage,
      vault: vault,
      authenticator: authenticator,
      now: () => DateTime.utc(2026, 7, 16, 12),
    );

    expect((await repository.setEnabled(true)).isFailure, isTrue);
    expect(authenticator.calls, 0);
    expect(vault.setCalls, 0);
  });
}

final class _Authenticator implements LocalAuthenticator {
  _Authenticator(this.result);
  final LocalAuthenticationResult result;
  int calls = 0;

  @override
  Future<LocalAuthenticationResult> authenticate() async {
    calls += 1;
    return result;
  }
}

final class _PolicyVault implements BiometricCredentialVault {
  int setCalls = 0;
  BiometricCredentialPolicy? policy;

  @override
  Future<bool> setBiometricPolicy({
    required LockedCredentialMetadata expected,
    required BiometricCredentialPolicy policy,
  }) async {
    setCalls += 1;
    this.policy = policy;
    return true;
  }

  @override
  Future<BiometricCredentialInspection> inspectForBiometricUnlock(
    DateTime now,
  ) => throw UnimplementedError();

  @override
  Future<DeviceCredential?> releaseAfterBiometric({
    required LockedCredentialMetadata expected,
    required DateTime now,
  }) => throw UnimplementedError();
}

final class _CredentialStorage implements DeviceCredentialStorage {
  _CredentialStorage(this.credential);
  final DeviceCredential credential;

  @override
  Future<DeviceCredential?> readDeviceCredential() async => credential;

  @override
  Future<bool> clearDeviceCredentialIfMatches({
    required String accountId,
    required String sessionId,
    required int generation,
  }) => throw UnimplementedError();

  @override
  Future<bool> rotateDeviceCredential({
    required DeviceCredential credential,
    required String expectedAccountId,
    required String expectedSessionId,
    required int expectedGeneration,
  }) => throw UnimplementedError();

  @override
  Future<bool> savePendingDeviceCredentialForOwner({
    required DeviceCredential credential,
    required String ownerId,
    required int attemptVersion,
  }) => throw UnimplementedError();
}

DeviceCredential _credential({DateTime? accessExpiresAt}) => DeviceCredential(
  accessToken: 'access-token',
  refreshToken: 'refresh-token',
  accountId: '7',
  sessionId: 'session-7',
  accessExpiresAt: accessExpiresAt ?? DateTime.utc(2026, 7, 16, 12, 5),
  refreshExpiresAt: DateTime.utc(2026, 7, 20),
  tokenVersion: 4,
  generation: 2,
  biometricPolicy: BiometricCredentialPolicy.disabled,
);
