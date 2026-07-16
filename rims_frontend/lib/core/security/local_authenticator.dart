import 'package:local_auth/local_auth.dart';

import '../result/failure.dart';
import '../result/result.dart';
import '../storage/app_secure_storage.dart';

enum LocalAuthenticationResult { success, cancelled, failed, unsupported }

abstract interface class LocalAuthenticator {
  Future<LocalAuthenticationResult> authenticate();
}

enum LocalAuthPlatformError {
  userCancelled,
  systemCancelled,
  unsupported,
  failed,
}

final class LocalAuthPlatformFailure implements Exception {
  const LocalAuthPlatformFailure(this.error);

  final LocalAuthPlatformError error;
}

abstract interface class LocalAuthPlatformBoundary {
  Future<bool> deviceSupportsAuthentication();

  Future<bool> hasEnrolledBiometrics();

  Future<bool> authenticateWithBiometrics();
}

final class PlatformLocalAuthenticator implements LocalAuthenticator {
  PlatformLocalAuthenticator({LocalAuthPlatformBoundary? boundary})
    : _boundary = boundary ?? _LocalAuthPluginBoundary();

  final LocalAuthPlatformBoundary _boundary;

  @override
  Future<LocalAuthenticationResult> authenticate() async {
    try {
      final supported = await _boundary.deviceSupportsAuthentication();
      final enrolled = supported && await _boundary.hasEnrolledBiometrics();
      if (!enrolled) return LocalAuthenticationResult.unsupported;
      return await _boundary.authenticateWithBiometrics()
          ? LocalAuthenticationResult.success
          : LocalAuthenticationResult.failed;
    } on LocalAuthPlatformFailure catch (failure) {
      return switch (failure.error) {
        LocalAuthPlatformError.userCancelled ||
        LocalAuthPlatformError.systemCancelled =>
          LocalAuthenticationResult.cancelled,
        LocalAuthPlatformError.unsupported =>
          LocalAuthenticationResult.unsupported,
        LocalAuthPlatformError.failed => LocalAuthenticationResult.failed,
      };
    } on Object {
      return LocalAuthenticationResult.failed;
    }
  }
}

final class _LocalAuthPluginBoundary implements LocalAuthPlatformBoundary {
  _LocalAuthPluginBoundary() : _localAuth = LocalAuthentication();

  final LocalAuthentication _localAuth;

  @override
  Future<bool> deviceSupportsAuthentication() => _localAuth.isDeviceSupported();

  @override
  Future<bool> hasEnrolledBiometrics() => _localAuth.canCheckBiometrics;

  @override
  Future<bool> authenticateWithBiometrics() async {
    try {
      return await _localAuth.authenticate(
        localizedReason: '验证身份以解锁 RIMS',
        biometricOnly: true,
        sensitiveTransaction: true,
        persistAcrossBackgrounding: false,
      );
    } on LocalAuthException catch (error) {
      throw LocalAuthPlatformFailure(_mapLocalAuthError(error.code));
    }
  }

  LocalAuthPlatformError _mapLocalAuthError(LocalAuthExceptionCode code) =>
      switch (code) {
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.userRequestedFallback =>
          LocalAuthPlatformError.userCancelled,
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.timeout =>
          LocalAuthPlatformError.systemCancelled,
        LocalAuthExceptionCode.noCredentialsSet ||
        LocalAuthExceptionCode.noBiometricsEnrolled ||
        LocalAuthExceptionCode.noBiometricHardware =>
          LocalAuthPlatformError.unsupported,
        _ => LocalAuthPlatformError.failed,
      };
}

final class LocalUnlockCoordinator {
  const LocalUnlockCoordinator({
    required this.authenticator,
    required this.vault,
    required this.now,
  });

  final LocalAuthenticator authenticator;
  final BiometricCredentialVault vault;
  final DateTime Function() now;

  Future<Result<DeviceCredential>> unlock() async {
    try {
      final inspectedAt = now().toUtc();
      final inspection = await vault.inspectForBiometricUnlock(inspectedAt);
      final metadata = inspection.metadata;
      if (inspection.availability !=
              BiometricCredentialAvailability.available ||
          metadata == null) {
        return const FailureResult(StateFailure(message: '请使用账号和密码登录'));
      }
      final authentication = await authenticator.authenticate();
      if (authentication != LocalAuthenticationResult.success) {
        return const FailureResult(StateFailure(message: '请使用账号和密码登录'));
      }
      final credential = await vault.releaseAfterBiometric(
        expected: metadata,
        now: now().toUtc(),
      );
      if (credential == null) {
        return const FailureResult(StateFailure(message: '本机凭据已变化，请重新登录'));
      }
      return Success(credential);
    } on Object {
      return const FailureResult(
        LocalStorageFailure(message: '无法读取本机安全凭据，请重新登录'),
      );
    }
  }
}
