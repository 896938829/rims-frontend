import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/features/auth/domain/services/authenticated_request_lease.dart';

void main() {
  test(
    'epoch change between credential and token reads rejects lease',
    () async {
      var epoch = 7;
      final storage = _LeaseStorage(_credential())
        ..onTokenRead = () => epoch += 1;
      final reader = StableAuthenticatedRequestLeaseReader(
        credentialStorage: storage,
        tokenStorage: storage,
        authEpochReader: () => epoch,
        canAuthenticateReader: () => true,
        accountIdReader: () => '7',
      );

      expect(await reader.read(), isNull);
    },
  );

  test('credential owner mismatch rejects lease', () async {
    final storage = _LeaseStorage(_credential());
    final reader = StableAuthenticatedRequestLeaseReader(
      credentialStorage: storage,
      tokenStorage: storage,
      authEpochReader: () => 7,
      canAuthenticateReader: () => true,
      accountIdReader: () => '8',
    );

    expect(await reader.read(), isNull);
  });

  test('stable owner-bound reads produce one authenticated lease', () async {
    final storage = _LeaseStorage(_credential());
    final reader = StableAuthenticatedRequestLeaseReader(
      credentialStorage: storage,
      tokenStorage: storage,
      authEpochReader: () => 7,
      canAuthenticateReader: () => true,
      accountIdReader: () => '7',
    );

    final lease = await reader.read();

    expect(lease?.token, 'access-1');
    expect(lease?.credential.sessionId, 'session-7');
    expect(lease?.authEpoch, 7);
  });
}

final class _LeaseStorage implements DeviceCredentialStorage, TokenStorage {
  _LeaseStorage(this.credential);

  DeviceCredential? credential;
  void Function()? onTokenRead;

  @override
  Future<DeviceCredential?> readDeviceCredential() async => credential;

  @override
  Future<String?> readAccessToken() async {
    onTokenRead?.call();
    return credential?.accessToken;
  }

  @override
  Future<void> clearAccessToken() async => credential = null;

  @override
  Future<void> saveAccessToken(String token) async =>
      throw UnsupportedError('not used');

  @override
  Future<bool> clearDeviceCredentialIfMatches({
    required String accountId,
    required String sessionId,
    required int generation,
  }) async => throw UnsupportedError('not used');

  @override
  Future<bool> rotateDeviceCredential({
    required DeviceCredential credential,
    required String expectedAccountId,
    required String expectedSessionId,
    required int expectedGeneration,
  }) async => throw UnsupportedError('not used');

  @override
  Future<bool> savePendingDeviceCredentialForOwner({
    required DeviceCredential credential,
    required String ownerId,
    required int attemptVersion,
  }) async => throw UnsupportedError('not used');
}

DeviceCredential _credential() => DeviceCredential(
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accountId: '7',
  sessionId: 'session-7',
  accessExpiresAt: DateTime.utc(2026, 7, 15, 3),
  refreshExpiresAt: DateTime.utc(2026, 8, 15, 3),
  tokenVersion: 5,
  generation: 1,
  biometricPolicy: BiometricCredentialPolicy.disabled,
);
