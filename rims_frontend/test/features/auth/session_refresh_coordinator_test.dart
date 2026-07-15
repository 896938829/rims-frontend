import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/auth/domain/services/session_refresh_coordinator.dart';

void main() {
  test('ten concurrent unauthorized requests perform one refresh', () async {
    final storage = _CoordinatorStorage(_credential());
    final repository = _RefreshRepository();
    final coordinator = _coordinator(storage, repository);

    final results = await Future.wait([
      for (var index = 0; index < 10; index += 1)
        coordinator.refreshAfterUnauthorized(
          failedCredential: _credential(),
          origin: SessionRefreshOrigin.request,
        ),
    ]);

    expect(repository.calls, 1);
    expect(results, everyElement(isA<Success<DeviceCredential>>()));
    expect(storage.credential?.generation, 2);
    expect(storage.credential?.refreshToken, 'refresh-2');
  });

  test(
    'refresh failure clears credentials and retains cleanup marker',
    () async {
      final order = <String>[];
      final storage = _CoordinatorStorage(_credential(), order: order);
      final repository = _RefreshRepository(
        result: const FailureResult(AuthenticationFailure()),
      );
      final coordinator = _coordinator(
        storage,
        repository,
        onFailClosed: (_) async => order.add('cleanup'),
      );

      final result = await coordinator.refreshAfterUnauthorized(
        failedCredential: _credential(),
        origin: SessionRefreshOrigin.request,
      );

      expect(result.isFailure, isTrue);
      expect(storage.credential, isNull);
      expect(storage.pendingAccountId, '7');
      expect(order, ['pending', 'clear', 'cleanup']);
    },
  );

  test(
    'server rotation followed by storage failure never reuses old refresh',
    () async {
      final order = <String>[];
      final storage = _CoordinatorStorage(_credential(), order: order)
        ..rotateError = StateError('injected atomic commit failure');
      final repository = _RefreshRepository();
      final coordinator = _coordinator(
        storage,
        repository,
        onFailClosed: (_) async => order.add('cleanup'),
      );

      final first = await coordinator.refreshAfterUnauthorized(
        failedCredential: _credential(),
        origin: SessionRefreshOrigin.request,
      );
      final second = await coordinator.refreshAfterUnauthorized(
        failedCredential: _credential(),
        origin: SessionRefreshOrigin.request,
      );

      expect(first.isFailure, isTrue);
      expect(second.isFailure, isTrue);
      expect(repository.calls, 1);
      expect(storage.credential, isNull);
      expect(storage.pendingAccountId, '7');
      expect(order, ['pending', 'clear', 'cleanup']);
    },
  );

  test(
    'logout wins against an in-flight refresh without resurrection',
    () async {
      final storage = _CoordinatorStorage(_credential());
      final release = Completer<void>();
      final repository = _RefreshRepository(release: release);
      final coordinator = _coordinator(storage, repository);

      final refreshing = coordinator.refreshAfterUnauthorized(
        failedCredential: _credential(),
        origin: SessionRefreshOrigin.request,
      );
      await repository.started.future;
      await coordinator.invalidateCurrent(
        expected: _credential(),
        retainPendingRevocation: true,
      );
      release.complete();
      final result = await refreshing;

      expect(result.isFailure, isTrue);
      expect(storage.credential, isNull);
      expect(storage.pendingAccountId, '7');
    },
  );

  test(
    'old account rotation cannot join or clear a new account credential',
    () async {
      final storage = _CoordinatorStorage(_credential());
      final release = Completer<void>();
      final repository = _RefreshRepository(release: release);
      var cleanupCalls = 0;
      final coordinator = _coordinator(
        storage,
        repository,
        onFailClosed: (_) async => cleanupCalls += 1,
      );

      final oldRefresh = coordinator.refreshAfterUnauthorized(
        failedCredential: _credential(),
        origin: SessionRefreshOrigin.request,
      );
      await repository.started.future;
      final newCredential = _credential(accountId: '8', sessionId: 'session-8');
      storage.credential = newCredential;
      final newRefresh = coordinator.refreshAfterUnauthorized(
        failedCredential: newCredential,
        origin: SessionRefreshOrigin.request,
      );
      release.complete();

      final results = await Future.wait([oldRefresh, newRefresh]);

      expect(repository.calls, 2);
      expect(results.first.isFailure, isTrue);
      expect(results.last.isSuccess, isTrue);
      expect(storage.credential?.accountId, '8');
      expect(storage.credential?.generation, 2);
      expect(storage.pendingAccountId, '7');
      expect(cleanupCalls, 0);
    },
  );

  test(
    'stale generation uses a newer commit but rejects future generation',
    () async {
      final current = _credential(
        accessToken: 'access-2',
        refreshToken: 'refresh-2',
        generation: 2,
      );
      final storage = _CoordinatorStorage(current);
      final repository = _RefreshRepository();
      final coordinator = _coordinator(storage, repository);

      final stale = await coordinator.refreshAfterUnauthorized(
        failedCredential: _credential(),
        origin: SessionRefreshOrigin.request,
      );
      final future = await coordinator.refreshAfterUnauthorized(
        failedCredential: _credential(generation: 3),
        origin: SessionRefreshOrigin.request,
      );

      expect(stale, isA<Success<DeviceCredential>>());
      expect((stale as Success<DeviceCredential>).data.generation, 2);
      expect(future.isFailure, isTrue);
      expect(repository.calls, 0);
    },
  );

  test(
    'queued writes refresh only for an explicit Sync Center command',
    () async {
      final storage = _CoordinatorStorage(_credential());
      final repository = _RefreshRepository();
      final coordinator = _coordinator(storage, repository);

      final background = await coordinator.refreshAfterUnauthorized(
        failedCredential: _credential(),
        origin: SessionRefreshOrigin.queuedWrite,
      );
      final explicit = await coordinator.refreshAfterUnauthorized(
        failedCredential: _credential(),
        origin: SessionRefreshOrigin.syncCenter,
      );

      expect(background.isFailure, isTrue);
      expect(explicit.isSuccess, isTrue);
      expect(repository.calls, 1);
    },
  );
}

SessionRefreshCoordinator _coordinator(
  _CoordinatorStorage storage,
  _RefreshRepository repository, {
  Future<void> Function(String accountId)? onFailClosed,
}) => SessionRefreshCoordinator(
  credentialStorage: storage,
  tokenStorage: storage,
  pendingRevocationStorage: storage,
  repository: repository,
  onFailClosed: onFailClosed,
);

final class _RefreshRepository implements SessionCredentialRepository {
  _RefreshRepository({this.result, this.release});

  final Result<DeviceCredential>? result;
  final Completer<void>? release;
  final Completer<void> started = Completer<void>();
  int calls = 0;

  @override
  Future<Result<DeviceCredential>> refreshCredential(
    DeviceCredential current,
  ) async {
    calls += 1;
    if (!started.isCompleted) started.complete();
    await release?.future;
    return result ??
        Success(
          _credential(
            accessToken: 'access-2',
            refreshToken: 'refresh-2',
            accountId: current.accountId,
            sessionId: current.sessionId,
            generation: current.generation + 1,
          ),
        );
  }
}

final class _CoordinatorStorage
    implements DeviceCredentialStorage, TokenStorage, PendingRevocationStorage {
  _CoordinatorStorage(this.credential, {this.order});

  DeviceCredential? credential;
  String? pendingAccountId;
  Object? rotateError;
  final List<String>? order;

  @override
  Future<bool> clearDeviceCredentialIfMatches({
    required String accountId,
    required String sessionId,
    required int generation,
  }) async {
    final current = credential;
    if (current?.accountId != accountId ||
        current?.sessionId != sessionId ||
        current?.generation != generation) {
      return false;
    }
    order?.add('clear');
    credential = null;
    return true;
  }

  @override
  Future<void> clearAccessToken() async {
    order?.add('clear');
    credential = null;
  }

  @override
  Future<void> clearPendingRevocationAccountId() async {
    pendingAccountId = null;
  }

  @override
  Future<DeviceCredential?> readDeviceCredential() async => credential;

  @override
  Future<String?> readAccessToken() async => credential?.accessToken;

  @override
  Future<String?> readPendingRevocationAccountId() async => pendingAccountId;

  @override
  Future<bool> rotateDeviceCredential({
    required DeviceCredential credential,
    required String expectedAccountId,
    required String expectedSessionId,
    required int expectedGeneration,
  }) async {
    if (rotateError case final error?) throw error;
    final current = this.credential;
    if (current?.accountId != expectedAccountId ||
        current?.sessionId != expectedSessionId ||
        current?.generation != expectedGeneration) {
      return false;
    }
    this.credential = credential;
    return true;
  }

  @override
  Future<void> saveAccessToken(String token) async =>
      throw UnsupportedError('device credentials only');

  @override
  Future<void> savePendingRevocationAccountId(String accountId) async {
    order?.add('pending');
    pendingAccountId = accountId;
  }

  @override
  Future<bool> savePendingDeviceCredentialForOwner({
    required DeviceCredential credential,
    required String ownerId,
    required int attemptVersion,
  }) async => throw UnsupportedError('not used');
}

DeviceCredential _credential({
  String accessToken = 'access-1',
  String refreshToken = 'refresh-1',
  String accountId = '7',
  String sessionId = 'session-7',
  int generation = 1,
}) => DeviceCredential(
  accessToken: accessToken,
  refreshToken: refreshToken,
  accountId: accountId,
  sessionId: sessionId,
  accessExpiresAt: DateTime.utc(2026, 7, 15, 3),
  refreshExpiresAt: DateTime.utc(2026, 8, 15, 3),
  tokenVersion: 5,
  generation: generation,
  biometricPolicy: BiometricCredentialPolicy.disabled,
);
