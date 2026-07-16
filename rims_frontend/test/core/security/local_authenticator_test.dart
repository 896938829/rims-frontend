import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/security/local_authenticator.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';

void main() {
  group('PlatformLocalAuthenticator', () {
    test('requires enrolled biometric support and maps success', () async {
      final boundary = _FakeLocalAuthBoundary();
      final authenticator = PlatformLocalAuthenticator(boundary: boundary);

      expect(
        await authenticator.authenticate(),
        LocalAuthenticationResult.success,
      );
      expect(boundary.authenticateCalls, 1);

      boundary.canCheckBiometrics = false;
      expect(
        await authenticator.authenticate(),
        LocalAuthenticationResult.unsupported,
      );
      expect(boundary.authenticateCalls, 1);
    });

    for (final entry in {
      LocalAuthPlatformError.userCancelled: LocalAuthenticationResult.cancelled,
      LocalAuthPlatformError.systemCancelled:
          LocalAuthenticationResult.cancelled,
      LocalAuthPlatformError.unsupported: LocalAuthenticationResult.unsupported,
      LocalAuthPlatformError.failed: LocalAuthenticationResult.failed,
    }.entries) {
      test('maps ${entry.key} without throwing', () async {
        final boundary = _FakeLocalAuthBoundary(error: entry.key);
        expect(
          await PlatformLocalAuthenticator(boundary: boundary).authenticate(),
          entry.value,
        );
      });
    }
  });

  group('LocalUnlockCoordinator', () {
    test(
      'releases the exact owner-bound requireUnlock credential after OS success',
      () async {
        final credential = _credential();
        final vault = _FakeVault(credential: credential);
        final authenticator = _FakeAuthenticator(
          LocalAuthenticationResult.success,
        );
        final coordinator = LocalUnlockCoordinator(
          authenticator: authenticator,
          vault: vault,
          now: () => DateTime.utc(2026, 7, 16, 12),
        );

        final result = await coordinator.unlock();

        expect(result, isA<Success<DeviceCredential>>());
        expect((result as Success<DeviceCredential>).data, same(credential));
        expect(vault.releaseCalls, 1);
        expect(vault.lastExpected?.accountId, '7');
        expect(authenticator.calls, 1);
      },
    );

    for (final outcome in [
      LocalAuthenticationResult.unsupported,
      LocalAuthenticationResult.failed,
      LocalAuthenticationResult.cancelled,
    ]) {
      test(
        '$outcome returns full-login path without releasing a credential',
        () async {
          final vault = _FakeVault(credential: _credential());
          final coordinator = LocalUnlockCoordinator(
            authenticator: _FakeAuthenticator(outcome),
            vault: vault,
            now: () => DateTime.utc(2026, 7, 16, 12),
          );

          final result = await coordinator.unlock();

          expect(result, isA<FailureResult<DeviceCredential>>());
          expect(vault.releaseCalls, 0);
        },
      );
    }

    test(
      'revoked expired malformed pending and disabled records never invoke OS auth',
      () async {
        for (final state in BiometricCredentialAvailability.values.where(
          (value) => value != BiometricCredentialAvailability.available,
        )) {
          final vault = _FakeVault(credential: null, forcedAvailability: state);
          final authenticator = _FakeAuthenticator(
            LocalAuthenticationResult.success,
          );
          final result = await LocalUnlockCoordinator(
            authenticator: authenticator,
            vault: vault,
            now: () => DateTime.utc(2026, 7, 16, 12),
          ).unlock();

          expect(
            result,
            isA<FailureResult<DeviceCredential>>(),
            reason: '$state',
          );
          expect(authenticator.calls, 0, reason: '$state');
          expect(vault.releaseCalls, 0, reason: '$state');
        }
      },
    );

    test('owner changes between inspection and release fail closed', () async {
      final vault = _FakeVault(
        credential: _credential(),
        replaceBeforeRelease: true,
      );
      final result = await LocalUnlockCoordinator(
        authenticator: _FakeAuthenticator(LocalAuthenticationResult.success),
        vault: vault,
        now: () => DateTime.utc(2026, 7, 16, 12),
      ).unlock();

      expect(result, isA<FailureResult<DeviceCredential>>());
      expect(vault.releaseCalls, 1);
    });
  });
}

final class _FakeLocalAuthBoundary implements LocalAuthPlatformBoundary {
  _FakeLocalAuthBoundary({this.error});

  bool supported = true;
  bool canCheckBiometrics = true;
  bool result = true;
  final LocalAuthPlatformError? error;
  int authenticateCalls = 0;

  @override
  Future<bool> deviceSupportsAuthentication() async => supported;

  @override
  Future<bool> hasEnrolledBiometrics() async => canCheckBiometrics;

  @override
  Future<bool> authenticateWithBiometrics() async {
    authenticateCalls += 1;
    if (error case final value?) throw LocalAuthPlatformFailure(value);
    return result;
  }
}

final class _FakeAuthenticator implements LocalAuthenticator {
  _FakeAuthenticator(this.result);
  final LocalAuthenticationResult result;
  int calls = 0;

  @override
  Future<LocalAuthenticationResult> authenticate() async {
    calls += 1;
    return result;
  }
}

final class _FakeVault implements BiometricCredentialVault {
  _FakeVault({
    required this.credential,
    this.forcedAvailability,
    this.replaceBeforeRelease = false,
  });
  DeviceCredential? credential;
  final BiometricCredentialAvailability? forcedAvailability;
  final bool replaceBeforeRelease;
  int releaseCalls = 0;
  LockedCredentialMetadata? lastExpected;

  @override
  Future<BiometricCredentialInspection> inspectForBiometricUnlock(
    DateTime now,
  ) async {
    final current = credential;
    if (forcedAvailability case final availability?) {
      return BiometricCredentialInspection(availability: availability);
    }
    return BiometricCredentialInspection(
      availability: BiometricCredentialAvailability.available,
      metadata: LockedCredentialMetadata.fromCredential(current!),
    );
  }

  @override
  Future<DeviceCredential?> releaseAfterBiometric({
    required LockedCredentialMetadata expected,
    required DateTime now,
  }) async {
    releaseCalls += 1;
    lastExpected = expected;
    if (replaceBeforeRelease) return null;
    return credential;
  }

  @override
  Future<bool> setBiometricPolicy({
    required LockedCredentialMetadata expected,
    required BiometricCredentialPolicy policy,
    DateTime? authenticatedAt,
  }) async => true;
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
