import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/core/storage/pending_revocation_journal.dart';
import 'package:rims_frontend/features/auth/domain/entities/auth_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/cached_auth_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  group('session revocation cleanup leases', () {
    const oldLease = SessionRevocationLease(
      accountId: '7',
      sessionId: 'session-old',
      generation: 3,
      authEpoch: 11,
    );
    const newLease = SessionRevocationLease(
      accountId: '7',
      sessionId: 'session-new',
      generation: 1,
      authEpoch: 12,
    );

    test('primary marker persists and clears by complete lease CAS', () async {
      final raw = _MemoryFlutterSecureStorage();
      final storage = AppSecureStorage(storage: raw);

      await storage.savePendingRevocationLease(oldLease);

      expect(await storage.readPendingRevocationLease(), oldLease);
      expect(
        await storage.clearPendingRevocationLeaseIfMatches(newLease),
        isFalse,
      );
      expect(await storage.readPendingRevocationLease(), oldLease);
      expect(
        await storage.clearPendingRevocationLeaseIfMatches(oldLease),
        isTrue,
      );
      expect(await storage.readPendingRevocationLease(), isNull);
    });

    test(
      'legacy account marker is migration input, not a session lease',
      () async {
        final raw = _MemoryFlutterSecureStorage()
          ..values[AppSecureStorage.kPendingRevocationAccountIdKey] = '7';
        final storage = AppSecureStorage(storage: raw);

        expect(await storage.readPendingRevocationLease(), isNull);
        expect(await storage.readPendingRevocationAccountId(), '7');
        expect(
          await storage.clearPendingRevocationLeaseIfMatches(oldLease),
          isFalse,
        );
        expect(await storage.readPendingRevocationAccountId(), '7');
      },
    );

    test(
      'fallback journal persists and removes complete leases by CAS',
      () async {
        final previousPlatform = SharedPreferencesAsyncPlatform.instance;
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.empty();
        addTearDown(
          () => SharedPreferencesAsyncPlatform.instance = previousPlatform,
        );
        final journal = SharedPreferencesPendingRevocationJournal();

        await journal.addLease(oldLease);
        await journal.addLease(newLease);
        await journal.removeLease(oldLease);

        final restarted = SharedPreferencesPendingRevocationJournal();
        expect(await restarted.readLeases(), {newLease});
        expect(await restarted.readAccountIds(), isEmpty);
      },
    );
  });

  group('device credential record v3', () {
    test('migrates a complete v2 owner-bound record to strict v3', () async {
      final raw = _MemoryFlutterSecureStorage()
        ..values[AppSecureStorage.kDeviceCredentialKey] = jsonEncode({
          'version': 2,
          'state': 'committed',
          'owner_id': 'owner-7',
          'attempt_version': 4,
          'latest_attempt_version': 4,
          'access_token': 'access-7',
          'refresh_token': 'refresh-7',
          'account_id': '7',
          'session_id': 'session-7',
          'access_expires_at': '2026-07-15T03:00:00.000Z',
          'refresh_expires_at': '2026-08-15T03:00:00.000Z',
          'token_version': 3,
          'generation': 9,
        });
      final storage = AppSecureStorage(storage: raw);

      final restored = await storage.readDeviceCredential();

      expect(restored, isNotNull);
      expect(restored!.accessToken, 'access-7');
      expect(restored.refreshToken, 'refresh-7');
      expect(restored.accountId, '7');
      expect(restored.sessionId, 'session-7');
      expect(restored.tokenVersion, 3);
      expect(restored.generation, 9);
      expect(restored.biometricPolicy, BiometricCredentialPolicy.disabled);
      expect(
        jsonDecode(
          raw.values[AppSecureStorage.kDeviceCredentialKey]!,
        )['version'],
        3,
      );
    });

    test('commits access and refresh atomically for one owner', () async {
      final raw = _MemoryFlutterSecureStorage();
      final storage = AppSecureStorage(storage: raw);
      final attempt = await storage.beginAccessTokenAttempt('owner-7');

      expect(
        await storage.savePendingDeviceCredentialForOwner(
          credential: _credential(),
          ownerId: 'owner-7',
          attemptVersion: attempt,
        ),
        isTrue,
      );
      expect(await storage.readDeviceCredential(), isNull);
      expect(
        await storage.commitAccessTokenForOwner(
          'owner-7',
          attemptVersion: attempt,
        ),
        isTrue,
      );

      final restored = await storage.readDeviceCredential();
      expect(restored?.accessToken, 'access-1');
      expect(restored?.refreshToken, 'refresh-1');
      final encoded = raw.values[AppSecureStorage.kDeviceCredentialKey]!;
      expect(encoded, contains('access-1'));
      expect(encoded, contains('refresh-1'));
    });

    test(
      'pending device credential quarantines a prior legacy token',
      () async {
        final raw = _MemoryFlutterSecureStorage()
          ..values[AppSecureStorage.kAccessTokenKey] = 'legacy-access';
        final storage = AppSecureStorage(storage: raw);
        final attempt = await storage.beginAccessTokenAttempt('owner-7');

        expect(
          await storage.savePendingDeviceCredentialForOwner(
            credential: _credential(),
            ownerId: 'owner-7',
            attemptVersion: attempt,
          ),
          isTrue,
        );
        expect(await storage.readAccessToken(), isNull);
        expect(
          await storage.clearAccessTokenForOwner(
            'owner-7',
            attemptVersion: attempt,
          ),
          isTrue,
        );
        expect(await storage.readAccessToken(), isNull);
      },
    );

    test('rotation requires matching owner session and generation', () async {
      final storage = AppSecureStorage(storage: _MemoryFlutterSecureStorage());
      final attempt = await storage.beginAccessTokenAttempt('owner-7');
      await storage.savePendingDeviceCredentialForOwner(
        credential: _credential(),
        ownerId: 'owner-7',
        attemptVersion: attempt,
      );
      await storage.commitAccessTokenForOwner(
        'owner-7',
        attemptVersion: attempt,
      );

      expect(
        await storage.rotateDeviceCredential(
          credential: _credential(
            accessToken: 'access-2',
            refreshToken: 'refresh-2',
            generation: 2,
          ),
          expectedAccountId: '8',
          expectedSessionId: 'session-7',
          expectedGeneration: 1,
        ),
        isFalse,
      );
      expect(
        await storage.rotateDeviceCredential(
          credential: _credential(
            accessToken: 'access-2',
            refreshToken: 'refresh-2',
            generation: 2,
          ),
          expectedAccountId: '7',
          expectedSessionId: 'other-session',
          expectedGeneration: 1,
        ),
        isFalse,
      );
      expect(
        await storage.rotateDeviceCredential(
          credential: _credential(
            accessToken: 'access-2',
            refreshToken: 'refresh-2',
            generation: 2,
          ),
          expectedAccountId: '7',
          expectedSessionId: 'session-7',
          expectedGeneration: 0,
        ),
        isFalse,
      );
      expect(
        await storage.rotateDeviceCredential(
          credential: _credential(
            accessToken: 'access-2',
            refreshToken: 'refresh-2',
            generation: 2,
          ),
          expectedAccountId: '7',
          expectedSessionId: 'session-7',
          expectedGeneration: 1,
        ),
        isTrue,
      );
      expect((await storage.readDeviceCredential())?.refreshToken, 'refresh-2');
    });

    test('failed atomic rotation leaves the previous pair intact', () async {
      final raw = _MemoryFlutterSecureStorage();
      final storage = AppSecureStorage(storage: raw);
      final attempt = await storage.beginAccessTokenAttempt('owner-7');
      await storage.savePendingDeviceCredentialForOwner(
        credential: _credential(),
        ownerId: 'owner-7',
        attemptVersion: attempt,
      );
      await storage.commitAccessTokenForOwner(
        'owner-7',
        attemptVersion: attempt,
      );
      raw.writeError = StateError('injected secure write failure');

      await expectLater(
        storage.rotateDeviceCredential(
          credential: _credential(
            accessToken: 'access-2',
            refreshToken: 'refresh-2',
            generation: 2,
          ),
          expectedAccountId: '7',
          expectedSessionId: 'session-7',
          expectedGeneration: 1,
        ),
        throwsStateError,
      );
      raw.writeError = null;
      final restored = await storage.readDeviceCredential();
      expect(restored?.accessToken, 'access-1');
      expect(restored?.refreshToken, 'refresh-1');
    });

    for (final fixture in <(String, Matcher)>[
      ('{broken', isA<MalformedCredentialRecordException>()),
      (
        jsonEncode({'version': 99}),
        isA<UnsupportedCredentialRecordException>(),
      ),
    ]) {
      test(
        'typed restore failure clears unsafe record ${fixture.$1}',
        () async {
          final raw = _MemoryFlutterSecureStorage()
            ..values[AppSecureStorage.kAccessTokenKey] = 'legacy-access'
            ..values[AppSecureStorage.kDeviceCredentialKey] = fixture.$1;
          final storage = AppSecureStorage(storage: raw);

          await expectLater(
            storage.readDeviceCredential(),
            throwsA(fixture.$2),
          );

          expect(
            raw.values,
            isNot(contains(AppSecureStorage.kDeviceCredentialKey)),
          );
          expect(await storage.readAccessToken(), isNull);
        },
      );
    }
  });

  test(
    'newer auth attempt rejects an older late response with the same token',
    () async {
      final raw = _MemoryFlutterSecureStorage();
      final storage = AppSecureStorage(storage: raw);
      final attemptA = await storage.beginAccessTokenAttempt('owner-a');
      final attemptB = await storage.beginAccessTokenAttempt('owner-b');

      expect(attemptA, 1);
      expect(attemptB, 2);
      expect(
        await storage.savePendingAccessTokenForOwner(
          token: 'T',
          ownerId: 'owner-b',
          attemptVersion: attemptB,
        ),
        isTrue,
      );
      expect(
        await storage.commitAccessTokenForOwner(
          'owner-b',
          attemptVersion: attemptB,
        ),
        isTrue,
      );
      expect(
        await storage.savePendingAccessTokenForOwner(
          token: 'T',
          ownerId: 'owner-a',
          attemptVersion: attemptA,
        ),
        isFalse,
      );
      expect(await storage.readAccessToken(), 'T');

      final restarted = AppSecureStorage(storage: raw);
      expect(await restarted.beginAccessTokenAttempt('owner-c'), 3);
    },
  );

  test('pending commit and abort use owner plus attempt version CAS', () async {
    final storage = AppSecureStorage(storage: _MemoryFlutterSecureStorage());
    final attemptA = await storage.beginAccessTokenAttempt('owner-a');
    expect(
      await storage.savePendingAccessTokenForOwner(
        token: 'old',
        ownerId: 'owner-a',
        attemptVersion: attemptA,
      ),
      isTrue,
    );
    final attemptB = await storage.beginAccessTokenAttempt('owner-b');
    expect(
      await storage.savePendingAccessTokenForOwner(
        token: 'new',
        ownerId: 'owner-b',
        attemptVersion: attemptB,
      ),
      isTrue,
    );

    final outcomes = await Future.wait([
      storage.commitAccessTokenForOwner('owner-b', attemptVersion: attemptB),
      storage.clearAccessTokenForOwner('owner-a', attemptVersion: attemptA),
    ]);

    expect(outcomes, [isTrue, isFalse]);
    expect(await storage.readAccessToken(), 'new');
  });

  test('pending token is never restored until its owner commits it', () async {
    final raw = _MemoryFlutterSecureStorage();
    final storage = AppSecureStorage(storage: raw);
    final attempt = await storage.beginAccessTokenAttempt('owner-a');
    expect(
      await storage.savePendingAccessTokenForOwner(
        token: 'T',
        ownerId: 'owner-a',
        attemptVersion: attempt,
      ),
      isTrue,
    );
    final restarted = AppSecureStorage(storage: raw);

    expect(await restarted.readAccessToken(), isNull);
    expect(
      await restarted.commitAccessTokenForOwner(
        'owner-a',
        attemptVersion: attempt,
      ),
      isTrue,
    );
    expect(await restarted.readAccessToken(), 'T');
  });

  test('token owner rollback cannot delete a newer equal token', () async {
    final raw = _MemoryFlutterSecureStorage();
    final storage = AppSecureStorage(storage: raw);
    final attemptA = await storage.beginAccessTokenAttempt('owner-a');
    expect(
      await storage.savePendingAccessTokenForOwner(
        token: 'T',
        ownerId: 'owner-a',
        attemptVersion: attemptA,
      ),
      isTrue,
    );
    final attemptB = await storage.beginAccessTokenAttempt('owner-b');
    expect(
      await storage.savePendingAccessTokenForOwner(
        token: 'T',
        ownerId: 'owner-b',
        attemptVersion: attemptB,
      ),
      isTrue,
    );
    expect(
      await storage.commitAccessTokenForOwner(
        'owner-b',
        attemptVersion: attemptB,
      ),
      isTrue,
    );
    final restarted = AppSecureStorage(storage: raw);

    expect(
      await restarted.clearAccessTokenForOwner(
        'owner-a',
        attemptVersion: attemptA,
      ),
      isFalse,
    );
    expect(await restarted.readAccessToken(), 'T');
    expect(
      await restarted.clearAccessTokenForOwner(
        'owner-b',
        attemptVersion: attemptB,
      ),
      isTrue,
    );
    expect(await restarted.readAccessToken(), isNull);
  });

  test(
    'a restarted process safely discards an abandoned pending token',
    () async {
      final raw = _MemoryFlutterSecureStorage();
      final storage = AppSecureStorage(storage: raw);
      final attempt = await storage.beginAccessTokenAttempt('crashed-owner');
      expect(
        await storage.savePendingAccessTokenForOwner(
          token: 'crashed-token',
          ownerId: 'crashed-owner',
          attemptVersion: attempt,
        ),
        isTrue,
      );
      final restarted = AppSecureStorage(storage: raw);

      expect(await restarted.readAccessToken(), isNull);
      expect(await restarted.clearPendingAccessToken(), isTrue);
      expect(
        await restarted.commitAccessTokenForOwner(
          'crashed-owner',
          attemptVersion: attempt,
        ),
        isFalse,
      );
    },
  );

  test('legacy plain tokens remain readable and clearable', () async {
    final raw = _MemoryFlutterSecureStorage()
      ..values[AppSecureStorage.kAccessTokenKey] = 'legacy-token';
    final storage = AppSecureStorage(storage: raw);

    expect(await storage.readAccessToken(), 'legacy-token');
    expect(await storage.clearAccessTokenIfMatches('legacy-token'), isTrue);
    expect(await storage.readAccessToken(), isNull);
  });

  test(
    'authenticated account pointer uses owner and attempt version CAS',
    () async {
      final storage = AppSecureStorage(storage: _MemoryFlutterSecureStorage());

      expect(
        await storage.saveAuthenticatedAccountProjection(
          accountId: '8',
          ownerId: 'owner-b',
          attemptVersion: 2,
        ),
        isTrue,
      );
      expect(
        await storage.saveAuthenticatedAccountProjection(
          accountId: '7',
          ownerId: 'owner-a',
          attemptVersion: 1,
        ),
        isFalse,
      );
      expect(await storage.readAuthenticatedAccountId(), '8');
      expect(
        await storage.clearAuthenticatedAccountProjection(
          ownerId: 'owner-a',
          attemptVersion: 1,
        ),
        isFalse,
      );
      expect(
        await storage.clearAuthenticatedAccountProjection(
          ownerId: 'owner-b',
          attemptVersion: 2,
        ),
        isTrue,
      );
      expect(await storage.readAuthenticatedAccountId(), isNull);
    },
  );

  test(
    'authenticated account cleanup requires the persisted auth epoch',
    () async {
      final storage = AppSecureStorage(storage: _MemoryFlutterSecureStorage());
      expect(
        await storage.saveAuthenticatedAccountProjection(
          accountId: '7',
          ownerId: 'owner-a',
          attemptVersion: 3,
          authEpoch: 11,
        ),
        isTrue,
      );

      expect(
        await storage.clearAuthenticatedAccountIfMatches(
          accountId: '7',
          authEpoch: 10,
        ),
        isFalse,
      );
      expect(await storage.readAuthenticatedAccountId(), '7');
      expect(
        await storage.clearAuthenticatedAccountIfMatches(
          accountId: '7',
          authEpoch: 11,
        ),
        isTrue,
      );
      expect(await storage.readAuthenticatedAccountId(), isNull);
    },
  );

  test('a new auth attempt safely migrates a legacy committed token', () async {
    final raw = _MemoryFlutterSecureStorage()
      ..values[AppSecureStorage.kAccessTokenKey] = 'legacy-token';
    final storage = AppSecureStorage(storage: raw);

    final attempt = await storage.beginAccessTokenAttempt('new-owner');

    expect(attempt, 1);
    expect(await storage.readAccessToken(), 'legacy-token');
    expect(
      await storage.savePendingAccessTokenForOwner(
        token: 'new-token',
        ownerId: 'new-owner',
        attemptVersion: attempt,
      ),
      isTrue,
    );
    expect(await storage.readAccessToken(), isNull);
    expect(
      await storage.commitAccessTokenForOwner(
        'new-owner',
        attemptVersion: attempt,
      ),
      isTrue,
    );
    expect(await storage.readAccessToken(), 'new-token');
  });

  test(
    'malformed versioned token records become typed restore failures',
    () async {
      final raw = _MemoryFlutterSecureStorage()
        ..values[AppSecureStorage.kAccessTokenKey] = '{broken';
      final storage = AppSecureStorage(storage: raw);
      final repository = CachedAuthRepository(
        delegate: const _NullAuthRepository(),
        store: MemoryOfflineStore(),
        tokenStorage: storage,
        accountStorage: storage,
        revocationStorage: storage,
        onSessionRevoked: () {},
      );

      final result = await repository.restoreSession();

      expect(
        result.when(success: (_) => null, failure: (failure) => failure),
        isA<LocalStorageFailure>(),
      );
    },
  );
}

final class _MemoryFlutterSecureStorage extends FlutterSecureStorage {
  _MemoryFlutterSecureStorage();

  final Map<String, String> values = {};
  Object? writeError;

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (writeError case final error?) throw error;
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

DeviceCredential _credential({
  String accessToken = 'access-1',
  String refreshToken = 'refresh-1',
  int generation = 1,
}) => DeviceCredential(
  accessToken: accessToken,
  refreshToken: refreshToken,
  accountId: '7',
  sessionId: 'session-7',
  accessExpiresAt: DateTime.utc(2026, 7, 15, 3),
  refreshExpiresAt: DateTime.utc(2026, 8, 15, 3),
  tokenVersion: 3,
  generation: generation,
  biometricPolicy: BiometricCredentialPolicy.disabled,
);

final class _NullAuthRepository implements AuthRepository {
  const _NullAuthRepository();

  @override
  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  }) async => const FailureResult(UnknownFailure());

  @override
  Future<void> logout() async {}

  @override
  Future<Result<AuthSession?>> restoreSession() async =>
      const Success<AuthSession?>(null);

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) async =>
      Success(warehouse);
}
