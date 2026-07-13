import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/features/auth/domain/entities/auth_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/cached_auth_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';

void main() {
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
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

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
