import '../../../../core/storage/app_secure_storage.dart';

final class AuthenticatedRequestLease {
  const AuthenticatedRequestLease({
    required this.token,
    required this.credential,
    required this.authEpoch,
  });

  final String token;
  final DeviceCredential credential;
  final int authEpoch;

  AuthenticatedRequestLease withCredential(DeviceCredential next) =>
      AuthenticatedRequestLease(
        token: next.accessToken,
        credential: next,
        authEpoch: authEpoch,
      );
}

final class AuthenticatedSessionCleanupLease {
  const AuthenticatedSessionCleanupLease({
    required this.request,
    required this.cleanupEpoch,
  });

  final AuthenticatedRequestLease request;
  final int cleanupEpoch;
}

typedef AuthenticatedRequestLeaseReader =
    Future<AuthenticatedRequestLease?> Function();

final class StableAuthenticatedRequestLeaseReader {
  const StableAuthenticatedRequestLeaseReader({
    required this.credentialStorage,
    required this.tokenStorage,
    required this.authEpochReader,
    required this.canAuthenticateReader,
    required this.accountIdReader,
  });

  final DeviceCredentialStorage credentialStorage;
  final TokenStorage tokenStorage;
  final int Function() authEpochReader;
  final bool Function() canAuthenticateReader;
  final String? Function() accountIdReader;

  Future<AuthenticatedRequestLease?> read() async {
    final expectedEpoch = authEpochReader();
    final expectedAccountId = accountIdReader();
    if (!canAuthenticateReader() || expectedAccountId == null) return null;

    final credential = await credentialStorage.readDeviceCredential();
    if (credential == null || credential.accountId != expectedAccountId) {
      return null;
    }
    final token = await tokenStorage.readAccessToken();
    if (token == null || token.isEmpty || token != credential.accessToken) {
      return null;
    }
    if (!canAuthenticateReader() ||
        authEpochReader() != expectedEpoch ||
        accountIdReader() != expectedAccountId) {
      return null;
    }
    return AuthenticatedRequestLease(
      token: token,
      credential: credential,
      authEpoch: expectedEpoch,
    );
  }
}
