import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/network/interceptors/auth_interceptor.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/core/storage/pending_revocation_journal.dart';
import 'package:rims_frontend/features/auth/domain/entities/auth_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/auth/domain/services/authenticated_request_lease.dart';
import 'package:rims_frontend/features/auth/domain/services/session_refresh_coordinator.dart';
import 'package:rims_frontend/features/offline/data/repositories/cached_auth_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../../support/unsupported_device_sessions.dart';

void main() {
  group('biometric runtime access lease', () {
    Future<AppSecureStorage> commitLocked(
      _MemoryFlutterSecureStorage raw, {
      DeviceCredential? credential,
      String ownerId = 'owner-7',
      DateTime Function()? now,
    }) async {
      final storage = AppSecureStorage(storage: raw, now: now);
      final attempt = await storage.beginAccessTokenAttempt(ownerId);
      await storage.savePendingDeviceCredentialForOwner(
        credential:
            credential ??
            _credential(
              accessExpiresAt: DateTime.utc(2099, 7, 15, 3),
              refreshExpiresAt: DateTime.utc(2099, 8, 15, 3),
              biometricPolicy: BiometricCredentialPolicy.requireUnlock,
            ),
        ownerId: ownerId,
        attemptVersion: attempt,
      );
      await storage.commitAccessTokenForOwner(ownerId, attemptVersion: attempt);
      return storage;
    }

    StableAuthenticatedRequestLeaseReader reader(
      AppSecureStorage storage, {
      String accountId = '7',
    }) => StableAuthenticatedRequestLeaseReader(
      credentialStorage: storage,
      tokenStorage: storage,
      authEpochReader: () => 4,
      canAuthenticateReader: () => true,
      accountIdReader: () => accountId,
    );

    Future<void> unlock(AppSecureStorage storage) async {
      final inspection = await storage.inspectForBiometricUnlock(
        DateTime.utc(2026, 7, 16),
      );
      expect(
        inspection.availability,
        BiometricCredentialAvailability.available,
      );
      expect(
        await storage.releaseAfterBiometric(
          expected: inspection.metadata!,
          now: DateTime.utc(2026, 7, 16),
        ),
        isNotNull,
      );
    }

    test(
      'injected clock expires a released biometric lease deterministically',
      () async {
        var currentTime = DateTime.utc(2026, 7, 16, 12);
        final raw = _MemoryFlutterSecureStorage();
        final storage = await commitLocked(
          raw,
          now: () => currentTime,
          credential: _credential(
            accessExpiresAt: currentTime.add(const Duration(minutes: 1)),
            refreshExpiresAt: currentTime.add(const Duration(days: 1)),
            biometricPolicy: BiometricCredentialPolicy.requireUnlock,
          ),
        );
        final inspection = await storage.inspectForBiometricUnlock(currentTime);
        expect(
          await storage.releaseAfterBiometric(
            expected: inspection.metadata!,
            now: currentTime,
          ),
          isNotNull,
        );

        expect((await reader(storage).read())?.token, 'access-1');
        currentTime = currentTime.add(const Duration(minutes: 1));
        expect(await reader(storage).read(), isNull);
        final staleCallerTime = currentTime.subtract(
          const Duration(minutes: 1),
        );
        expect(
          (await storage.inspectForBiometricUnlock(
            staleCallerTime,
          )).availability,
          BiometricCredentialAvailability.expired,
        );
        expect(
          await storage.releaseAfterBiometric(
            expected: inspection.metadata!,
            now: staleCallerTime,
          ),
          isNull,
        );
      },
    );

    test(
      'injected clock rejects policy release after credential expiry',
      () async {
        var currentTime = DateTime.utc(2026, 7, 16, 12);
        final raw = _MemoryFlutterSecureStorage();
        final storage = await commitLocked(
          raw,
          now: () => currentTime,
          credential: _credential(
            accessExpiresAt: currentTime.add(const Duration(minutes: 1)),
            refreshExpiresAt: currentTime.add(const Duration(days: 1)),
            biometricPolicy: BiometricCredentialPolicy.disabled,
          ),
        );
        final credential = (await storage.readDeviceCredential())!;
        final authenticatedAt = currentTime;
        currentTime = currentTime.add(const Duration(minutes: 1));

        expect(
          await storage.setBiometricPolicy(
            expected: LockedCredentialMetadata.fromCredential(credential),
            policy: BiometricCredentialPolicy.requireUnlock,
            authenticatedAt: authenticatedAt,
          ),
          isFalse,
        );
        expect(
          (await storage.readDeviceCredential())?.biometricPolicy,
          BiometricCredentialPolicy.disabled,
        );
      },
    );

    test(
      'injected clock preserves exact refresh lease but not a new storage instance',
      () async {
        final currentTime = DateTime.utc(2026, 7, 16, 12);
        final raw = _MemoryFlutterSecureStorage();
        final storage = await commitLocked(
          raw,
          now: () => currentTime,
          credential: _credential(
            accessExpiresAt: currentTime.add(const Duration(hours: 1)),
            refreshExpiresAt: currentTime.add(const Duration(days: 1)),
            biometricPolicy: BiometricCredentialPolicy.requireUnlock,
          ),
        );
        final inspection = await storage.inspectForBiometricUnlock(currentTime);
        await storage.releaseAfterBiometric(
          expected: inspection.metadata!,
          now: currentTime,
        );
        final before = (await storage.readDeviceCredential())!;

        expect(
          await storage.rotateDeviceCredential(
            credential: _credential(
              accessToken: 'access-2',
              refreshToken: 'refresh-2',
              generation: before.generation + 1,
              accessExpiresAt: currentTime.add(const Duration(hours: 1)),
              refreshExpiresAt: currentTime.add(const Duration(days: 1)),
              biometricPolicy: BiometricCredentialPolicy.requireUnlock,
            ),
            expectedAccountId: before.accountId,
            expectedSessionId: before.sessionId,
            expectedGeneration: before.generation,
          ),
          isTrue,
        );
        expect((await reader(storage).read())?.token, 'access-2');

        final restarted = AppSecureStorage(
          storage: raw,
          now: () => currentTime,
        );
        expect(await reader(restarted).read(), isNull);
      },
    );

    test(
      'biometric release authorizes the stable request reader only in this process',
      () async {
        final raw = _MemoryFlutterSecureStorage();
        final storage = await commitLocked(raw);

        expect(await reader(storage).read(), isNull);
        await unlock(storage);
        expect((await reader(storage).read())?.token, 'access-1');

        final restarted = AppSecureStorage(storage: raw);
        expect(await reader(restarted).read(), isNull);
      },
    );

    test(
      'new login owner invalidates while exact refresh rotation migrates the lease',
      () async {
        final raw = _MemoryFlutterSecureStorage();
        final storage = await commitLocked(raw);
        await unlock(storage);
        expect((await reader(storage).read())?.token, 'access-1');

        await storage.beginAccessTokenAttempt('owner-new');
        expect(await reader(storage).read(), isNull);

        final rotatedRaw = _MemoryFlutterSecureStorage();
        final rotatedStorage = await commitLocked(rotatedRaw);
        await unlock(rotatedStorage);
        expect((await reader(rotatedStorage).read())?.token, 'access-1');
        final current = (await rotatedStorage.readDeviceCredential())!;
        expect(
          await rotatedStorage.rotateDeviceCredential(
            credential: _credential(
              accessToken: 'access-2',
              refreshToken: 'refresh-2',
              generation: 2,
              accessExpiresAt: DateTime.utc(2099, 7, 15, 3),
              refreshExpiresAt: DateTime.utc(2099, 8, 15, 3),
              biometricPolicy: BiometricCredentialPolicy.requireUnlock,
            ),
            expectedAccountId: current.accountId,
            expectedSessionId: current.sessionId,
            expectedGeneration: current.generation,
          ),
          isTrue,
        );
        expect((await reader(rotatedStorage).read())?.token, 'access-2');
        expect(
          await reader(AppSecureStorage(storage: rotatedRaw)).read(),
          isNull,
        );
      },
    );

    test(
      'authenticated policy enable grants only the current exact session a lease',
      () async {
        final raw = _MemoryFlutterSecureStorage();
        final storage = await commitLocked(
          raw,
          credential: _credential(
            accessExpiresAt: DateTime.utc(2099, 7, 15, 3),
            refreshExpiresAt: DateTime.utc(2099, 8, 15, 3),
            biometricPolicy: BiometricCredentialPolicy.disabled,
          ),
        );
        final current = (await storage.readDeviceCredential())!;

        expect(
          await storage.setBiometricPolicy(
            expected: LockedCredentialMetadata.fromCredential(current),
            policy: BiometricCredentialPolicy.requireUnlock,
            authenticatedAt: DateTime.utc(2026, 7, 16),
          ),
          isTrue,
        );
        expect((await reader(storage).read())?.token, 'access-1');
        expect(await reader(AppSecureStorage(storage: raw)).read(), isNull);
      },
    );

    test(
      'unlocked 401 refresh replays and keeps later requests authorized',
      () async {
        final raw = _MemoryFlutterSecureStorage();
        final storage = await commitLocked(raw);
        await unlock(storage);
        final leaseReader = reader(storage);
        final repository = _RotatingCredentialRepository();
        final coordinator = SessionRefreshCoordinator(
          credentialStorage: storage,
          tokenStorage: storage,
          pendingRevocationStorage: storage,
          repository: repository,
          authenticatedRequestLeaseReader: leaseReader.read,
        );
        final adapter = _BiometricRotationAdapter();
        final dio = Dio()..httpClientAdapter = adapter;
        dio.interceptors.add(
          AuthInterceptor(
            authenticatedRequestLeaseReader: leaseReader.read,
            refreshCoordinator: coordinator,
            requestExecutor: dio.fetch,
          ),
        );

        expect((await dio.get<dynamic>('/first')).statusCode, 200);
        expect((await leaseReader.read())?.token, 'access-2');
        expect((await dio.get<dynamic>('/later')).statusCode, 200);
        expect(repository.calls, 1);
        expect(adapter.authorizations, [
          'Bearer access-1',
          'Bearer access-2',
          'Bearer access-2',
        ]);
      },
    );

    test(
      'rotation security mismatch rejects and clears the runtime lease',
      () async {
        final storage = await commitLocked(_MemoryFlutterSecureStorage());
        await unlock(storage);
        final current = (await storage.readDeviceCredential())!;

        expect(
          await storage.rotateDeviceCredential(
            credential: _credential(
              accessToken: 'access-2',
              refreshToken: 'refresh-2',
              generation: 2,
              tokenVersion: current.tokenVersion + 1,
              accessExpiresAt: DateTime.utc(2099, 7, 15, 3),
              refreshExpiresAt: DateTime.utc(2099, 8, 15, 3),
              biometricPolicy: BiometricCredentialPolicy.requireUnlock,
            ),
            expectedAccountId: current.accountId,
            expectedSessionId: current.sessionId,
            expectedGeneration: current.generation,
          ),
          isFalse,
        );
        expect(await reader(storage).read(), isNull);
      },
    );

    test(
      'revocation debt and logout immediately invalidate the lease',
      () async {
        final revoked = await commitLocked(_MemoryFlutterSecureStorage());
        await unlock(revoked);
        expect((await reader(revoked).read())?.token, 'access-1');
        await revoked.savePendingRevocationLease(
          const SessionRevocationLease(
            accountId: '7',
            sessionId: 'session-7',
            generation: 1,
            authEpoch: 4,
          ),
        );
        expect(await reader(revoked).read(), isNull);

        final loggedOut = await commitLocked(_MemoryFlutterSecureStorage());
        await unlock(loggedOut);
        expect((await reader(loggedOut).read())?.token, 'access-1');
        await loggedOut.clearAccessToken();
        expect(await reader(loggedOut).read(), isNull);
      },
    );

    test(
      'policy changes and a different account session cannot inherit the lease',
      () async {
        final raw = _MemoryFlutterSecureStorage();
        final storage = await commitLocked(raw);
        await unlock(storage);
        expect((await reader(storage).read())?.token, 'access-1');
        final first = (await storage.readDeviceCredential())!;

        expect(
          await storage.setBiometricPolicy(
            expected: LockedCredentialMetadata.fromCredential(first),
            policy: BiometricCredentialPolicy.disabled,
          ),
          isTrue,
        );
        final disabled = (await storage.readDeviceCredential())!;
        expect(
          await storage.setBiometricPolicy(
            expected: LockedCredentialMetadata.fromCredential(disabled),
            policy: BiometricCredentialPolicy.requireUnlock,
          ),
          isTrue,
        );
        expect(await reader(storage).read(), isNull);

        final attempt = await storage.beginAccessTokenAttempt('owner-8');
        await storage.savePendingDeviceCredentialForOwner(
          credential: _credential(
            accountId: '8',
            sessionId: 'session-8',
            accessExpiresAt: DateTime.utc(2099, 7, 15, 3),
            refreshExpiresAt: DateTime.utc(2099, 8, 15, 3),
            biometricPolicy: BiometricCredentialPolicy.requireUnlock,
          ),
          ownerId: 'owner-8',
          attemptVersion: attempt,
        );
        await storage.commitAccessTokenForOwner(
          'owner-8',
          attemptVersion: attempt,
        );
        expect(await reader(storage, accountId: '8').read(), isNull);
      },
    );
  });

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

  group('biometric credential vault', () {
    test(
      'locked credential is invisible to normal token reads and released by exact CAS',
      () async {
        final raw = _MemoryFlutterSecureStorage();
        final storage = AppSecureStorage(storage: raw);
        final attempt = await storage.beginAccessTokenAttempt('owner-7');
        expect(
          await storage.savePendingDeviceCredentialForOwner(
            credential: _credential(
              accessExpiresAt: DateTime.utc(2026, 7, 20),
              biometricPolicy: BiometricCredentialPolicy.requireUnlock,
            ),
            ownerId: 'owner-7',
            attemptVersion: attempt,
          ),
          isTrue,
        );
        expect(
          await storage.commitAccessTokenForOwner(
            'owner-7',
            attemptVersion: attempt,
          ),
          isTrue,
        );

        expect(await storage.readAccessToken(), isNull);
        final inspection = await storage.inspectForBiometricUnlock(
          DateTime.utc(2026, 7, 16),
        );
        expect(
          inspection.availability,
          BiometricCredentialAvailability.available,
        );
        final released = await storage.releaseAfterBiometric(
          expected: inspection.metadata!,
          now: DateTime.utc(2026, 7, 16),
        );
        expect(released?.accessToken, 'access-1');

        final wrong = LockedCredentialMetadata(
          accountId: '7',
          sessionId: 'other',
          generation: 1,
          tokenVersion: 3,
          refreshExpiresAt: DateTime.utc(2026, 8, 15, 3),
        );
        expect(
          await storage.releaseAfterBiometric(
            expected: wrong,
            now: DateTime.utc(2026, 7, 16),
          ),
          isNull,
        );
      },
    );

    test('expiry revocation debt and pending state fail closed', () async {
      Future<AppSecureStorage> committed(DeviceCredential credential) async {
        final storage = AppSecureStorage(
          storage: _MemoryFlutterSecureStorage(),
        );
        final attempt = await storage.beginAccessTokenAttempt('owner-7');
        await storage.savePendingDeviceCredentialForOwner(
          credential: credential,
          ownerId: 'owner-7',
          attemptVersion: attempt,
        );
        await storage.commitAccessTokenForOwner(
          'owner-7',
          attemptVersion: attempt,
        );
        return storage;
      }

      final expired = await committed(
        _credential(
          biometricPolicy: BiometricCredentialPolicy.requireUnlock,
          refreshExpiresAt: DateTime.utc(2026, 7, 15, 4),
        ),
      );
      expect(
        (await expired.inspectForBiometricUnlock(
          DateTime.utc(2026, 7, 16),
        )).availability,
        BiometricCredentialAvailability.expired,
      );

      final accessExpired = await committed(
        _credential(
          accessExpiresAt: DateTime.utc(2026, 7, 15, 4),
          refreshExpiresAt: DateTime.utc(2026, 8, 15, 4),
          biometricPolicy: BiometricCredentialPolicy.requireUnlock,
        ),
      );
      expect(
        (await accessExpired.inspectForBiometricUnlock(
          DateTime.utc(2026, 7, 16),
        )).availability,
        BiometricCredentialAvailability.expired,
      );

      final revoked = await committed(
        _credential(
          accessExpiresAt: DateTime.utc(2026, 7, 20),
          biometricPolicy: BiometricCredentialPolicy.requireUnlock,
        ),
      );
      await revoked.savePendingRevocationLease(
        const SessionRevocationLease(
          accountId: '7',
          sessionId: 'session-7',
          generation: 1,
          authEpoch: 4,
        ),
      );
      expect(
        (await revoked.inspectForBiometricUnlock(
          DateTime.utc(2026, 7, 16),
        )).availability,
        BiometricCredentialAvailability.revoked,
      );

      final pending = AppSecureStorage(storage: _MemoryFlutterSecureStorage());
      final attempt = await pending.beginAccessTokenAttempt('owner-7');
      await pending.savePendingDeviceCredentialForOwner(
        credential: _credential(
          biometricPolicy: BiometricCredentialPolicy.requireUnlock,
        ),
        ownerId: 'owner-7',
        attemptVersion: attempt,
      );
      expect(
        (await pending.inspectForBiometricUnlock(
          DateTime.utc(2026, 7, 16),
        )).availability,
        BiometricCredentialAvailability.pending,
      );
    });

    test(
      'policy update preserves token expiry version and generation',
      () async {
        final storage = AppSecureStorage(
          storage: _MemoryFlutterSecureStorage(),
        );
        final attempt = await storage.beginAccessTokenAttempt('owner-7');
        await storage.savePendingDeviceCredentialForOwner(
          credential: _credential(accessExpiresAt: DateTime.utc(2026, 7, 20)),
          ownerId: 'owner-7',
          attemptVersion: attempt,
        );
        await storage.commitAccessTokenForOwner(
          'owner-7',
          attemptVersion: attempt,
        );
        final before = (await storage.readDeviceCredential())!;

        expect(
          await storage.setBiometricPolicy(
            expected: LockedCredentialMetadata.fromCredential(before),
            policy: BiometricCredentialPolicy.requireUnlock,
          ),
          isTrue,
        );
        final rawInspection = await storage.inspectForBiometricUnlock(
          DateTime.utc(2026, 7, 16),
        );
        final after = await storage.releaseAfterBiometric(
          expected: rawInspection.metadata!,
          now: DateTime.utc(2026, 7, 16),
        );
        expect(after?.generation, before.generation);
        expect(after?.refreshExpiresAt, before.refreshExpiresAt);
        expect(after?.tokenVersion, before.tokenVersion);
        expect(after?.biometricPolicy, BiometricCredentialPolicy.requireUnlock);
      },
    );
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

final class _RotatingCredentialRepository
    implements SessionCredentialRepository {
  int calls = 0;

  @override
  Future<Result<DeviceCredential>> refreshCredential(
    DeviceCredential current,
  ) async {
    calls += 1;
    return Success(
      DeviceCredential(
        accessToken: 'access-2',
        refreshToken: 'refresh-2',
        accountId: current.accountId,
        sessionId: current.sessionId,
        accessExpiresAt: DateTime.utc(2099, 7, 15, 4),
        refreshExpiresAt: current.refreshExpiresAt,
        tokenVersion: current.tokenVersion,
        generation: current.generation + 1,
        biometricPolicy: current.biometricPolicy,
      ),
    );
  }
}

final class _BiometricRotationAdapter implements HttpClientAdapter {
  final List<String?> authorizations = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final authorization = options.headers['Authorization'] as String?;
    authorizations.add(authorization);
    return ResponseBody.fromString(
      'response',
      authorization == 'Bearer access-1' ? 401 : 200,
    );
  }

  @override
  void close({bool force = false}) {}
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
  String accountId = '7',
  String sessionId = 'session-7',
  int generation = 1,
  int tokenVersion = 3,
  DateTime? accessExpiresAt,
  DateTime? refreshExpiresAt,
  BiometricCredentialPolicy biometricPolicy =
      BiometricCredentialPolicy.disabled,
}) => DeviceCredential(
  accessToken: accessToken,
  refreshToken: refreshToken,
  accountId: accountId,
  sessionId: sessionId,
  accessExpiresAt: accessExpiresAt ?? DateTime.utc(2026, 7, 15, 3),
  refreshExpiresAt: refreshExpiresAt ?? DateTime.utc(2026, 8, 15, 3),
  tokenVersion: tokenVersion,
  generation: generation,
  biometricPolicy: biometricPolicy,
);

final class _NullAuthRepository
    with UnsupportedDeviceSessions
    implements AuthRepository {
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
