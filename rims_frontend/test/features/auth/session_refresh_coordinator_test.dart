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

  test('fail closed blocks memory before marker clear and ownership', () async {
    final order = <String>[];
    final storage = _CoordinatorStorage(_credential(), order: order)
      ..logReads = true;
    final recovery = _CoordinatorFailureRecovery(storage, order);
    var canAuthenticate = true;
    final coordinator = SessionRefreshCoordinator(
      credentialStorage: storage,
      tokenStorage: storage,
      pendingRevocationStorage: storage,
      repository: _RefreshRepository(
        result: const FailureResult(AuthenticationFailure()),
        order: order,
      ),
      blockAuthentication: (_) {
        order.add('block');
        canAuthenticate = false;
      },
      failureRecovery: recovery,
    );

    final result = await coordinator.refreshAfterUnauthorized(
      failedCredential: _credential(),
      origin: SessionRefreshOrigin.request,
    );

    expect(result.isFailure, isTrue);
    expect(canAuthenticate, isFalse);
    expect(order, ['read', 'remote', 'block', 'pending', 'clear', 'ownership']);
    expect(recovery.credentialQuarantined, isTrue);
  });

  test(
    'dual credential clear failure remains memory fail closed and typed',
    () async {
      final order = <String>[];
      final storage = _CoordinatorStorage(_credential(), order: order)
        ..logClearAttempts = true
        ..conditionalClearError = StateError('conditional clear failed')
        ..fallbackClearError = StateError('fallback clear failed');
      final recovery = _CoordinatorFailureRecovery(storage, order);
      final repository = _RefreshRepository(
        result: const FailureResult(AuthenticationFailure()),
      );
      var canAuthenticate = true;
      final coordinator = SessionRefreshCoordinator(
        credentialStorage: storage,
        tokenStorage: storage,
        pendingRevocationStorage: storage,
        repository: repository,
        blockAuthentication: (_) {
          order.add('block');
          canAuthenticate = false;
        },
        failureRecovery: recovery,
      );

      final result = await coordinator.refreshAfterUnauthorized(
        failedCredential: _credential(),
        origin: SessionRefreshOrigin.request,
      );

      expect(result, isA<FailureResult<DeviceCredential>>());
      expect(
        (result as FailureResult<DeviceCredential>).failure,
        isA<RevocationCleanupFailure>(),
      );
      expect(canAuthenticate, isFalse);
      expect(storage.credential, isNotNull);
      expect(storage.pendingAccountId, '7');
      expect(recovery.credentialQuarantined, isFalse);
      expect(order, [
        'block',
        'pending',
        'conditional-clear',
        'fallback-clear',
        'ownership',
      ]);

      final quarantined = await coordinator.refreshAfterUnauthorized(
        failedCredential: _credential(),
        origin: SessionRefreshOrigin.request,
      );

      expect(quarantined, isA<FailureResult<DeviceCredential>>());
      expect(repository.calls, 1);

      storage
        ..credential = _credential(sessionId: 'new-session')
        ..conditionalClearError = null
        ..fallbackClearError = null;
      repository.result = Success(
        _credential(
          accessToken: 'access-new-2',
          refreshToken: 'refresh-new-2',
          sessionId: 'new-session',
          generation: 2,
        ),
      );
      final newSession = await coordinator.refreshAfterUnauthorized(
        failedCredential: _credential(sessionId: 'new-session'),
        origin: SessionRefreshOrigin.request,
      );

      expect(newSession, isA<Success<DeviceCredential>>());
      expect(repository.calls, 2);
    },
  );

  test('initial credential read failure executes typed fail closed', () async {
    final storage = _CoordinatorStorage(_credential())
      ..nextReadError = StateError('secure read failed');
    final repository = _RefreshRepository();
    var canAuthenticate = true;
    final coordinator = SessionRefreshCoordinator(
      credentialStorage: storage,
      tokenStorage: storage,
      pendingRevocationStorage: storage,
      repository: repository,
      blockAuthentication: (_) => canAuthenticate = false,
    );

    final result = await coordinator.refreshAfterUnauthorized(
      failedCredential: _credential(),
      origin: SessionRefreshOrigin.request,
    );

    expect(result, isA<FailureResult<DeviceCredential>>());
    expect((result as FailureResult<DeviceCredential>).failure, isA<Failure>());
    expect(canAuthenticate, isFalse);
    expect(storage.credential, isNull);
    expect(storage.pendingAccountId, '7');
    expect(repository.calls, 0);
  });

  test('higher generation still merges after an older quarantine', () async {
    final storage = _CoordinatorStorage(_credential())
      ..conditionalClearError = StateError('conditional clear failed')
      ..fallbackClearError = StateError('fallback clear failed');
    final repository = _RefreshRepository(
      result: const FailureResult(AuthenticationFailure()),
    );
    final coordinator = _coordinator(storage, repository);

    expect(
      await coordinator.refreshAfterUnauthorized(
        failedCredential: _credential(),
        origin: SessionRefreshOrigin.request,
      ),
      isA<FailureResult<DeviceCredential>>(),
    );
    storage
      ..credential = _credential(
        accessToken: 'access-2',
        refreshToken: 'refresh-2',
        generation: 2,
      )
      ..conditionalClearError = null
      ..fallbackClearError = null;

    final merged = await coordinator.refreshAfterUnauthorized(
      failedCredential: _credential(),
      origin: SessionRefreshOrigin.request,
    );

    expect(merged, isA<Success<DeviceCredential>>());
    expect((merged as Success<DeviceCredential>).data.generation, 2);
    expect(repository.calls, 1);
  });

  test(
    'throwing refresh repository returns a typed fail-closed result',
    () async {
      final storage = _CoordinatorStorage(_credential());
      final repository = _RefreshRepository(
        throwError: StateError('injected refresh exception'),
      );
      final coordinator = _coordinator(storage, repository);

      final result = await coordinator.refreshAfterUnauthorized(
        failedCredential: _credential(),
        origin: SessionRefreshOrigin.request,
      );

      expect(result, isA<FailureResult<DeviceCredential>>());
      expect(storage.credential, isNull);
      expect(storage.pendingAccountId, '7');
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

  test('future failed generation fails closed for the same identity', () async {
    final storage = _CoordinatorStorage(_credential());
    final repository = _RefreshRepository();
    var invalidations = 0;
    final coordinator = _coordinator(
      storage,
      repository,
      onFailClosed: (_) async => invalidations += 1,
    );

    final result = await coordinator.refreshAfterUnauthorized(
      failedCredential: _credential(generation: 2),
      origin: SessionRefreshOrigin.request,
    );

    expect(result.isFailure, isTrue);
    expect(storage.credential, isNull);
    expect(storage.pendingAccountId, '7');
    expect(invalidations, 1);
    expect(repository.calls, 0);
  });

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
  _RefreshRepository({this.result, this.release, this.throwError, this.order});

  Result<DeviceCredential>? result;
  final Completer<void>? release;
  final Object? throwError;
  final List<String>? order;
  final Completer<void> started = Completer<void>();
  int calls = 0;

  @override
  Future<Result<DeviceCredential>> refreshCredential(
    DeviceCredential current,
  ) async {
    calls += 1;
    order?.add('remote');
    if (!started.isCompleted) started.complete();
    await release?.future;
    if (throwError case final error?) throw error;
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
  Object? conditionalClearError;
  Object? fallbackClearError;
  Object? nextReadError;
  bool logClearAttempts = false;
  bool logReads = false;
  final List<String>? order;

  @override
  Future<bool> clearDeviceCredentialIfMatches({
    required String accountId,
    required String sessionId,
    required int generation,
  }) async {
    if (logClearAttempts) order?.add('conditional-clear');
    if (conditionalClearError case final error?) throw error;
    final current = credential;
    if (current?.accountId != accountId ||
        current?.sessionId != sessionId ||
        current?.generation != generation) {
      return false;
    }
    if (!logClearAttempts) order?.add('clear');
    credential = null;
    return true;
  }

  @override
  Future<void> clearAccessToken() async {
    if (fallbackClearError case final error?) {
      order?.add('fallback-clear');
      throw error;
    }
    order?.add('clear');
    credential = null;
  }

  @override
  Future<void> clearPendingRevocationAccountId() async {
    pendingAccountId = null;
  }

  @override
  Future<DeviceCredential?> readDeviceCredential() async {
    if (logReads) order?.add('read');
    if (nextReadError case final error?) {
      nextReadError = null;
      throw error;
    }
    return credential;
  }

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

final class _CoordinatorFailureRecovery implements SessionFailureRecovery {
  _CoordinatorFailureRecovery(this.storage, this.order);

  final _CoordinatorStorage storage;
  final List<String> order;
  bool? credentialQuarantined;

  @override
  Future<Failure?> retainPendingRevocation(String accountId) async {
    order.add('pending');
    storage.pendingAccountId = accountId;
    return null;
  }

  @override
  Future<Failure?> completeOwnershipCleanup({
    required String accountId,
    required bool credentialQuarantined,
  }) async {
    order.add('ownership');
    this.credentialQuarantined = credentialQuarantined;
    return null;
  }
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
