import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

abstract interface class TokenStorage {
  Future<void> saveAccessToken(String token);

  Future<String?> readAccessToken();

  Future<void> clearAccessToken();
}

abstract interface class ConditionalTokenStorage {
  Future<bool> clearAccessTokenIfMatches(String expectedToken);
}

abstract interface class AuthTokenTransactionStorage {
  Future<void> saveAccessTokenForOwner({
    required String token,
    required String ownerId,
  });

  Future<bool> clearAccessTokenForOwner(String ownerId);
}

abstract interface class OfflineDatabaseKeyStorage {
  Future<void> saveOfflineDatabaseKey(String key);

  Future<String?> readOfflineDatabaseKey();
}

abstract interface class AuthenticatedAccountStorage {
  Future<void> saveAuthenticatedAccountId(String accountId);

  Future<String?> readAuthenticatedAccountId();

  Future<void> clearAuthenticatedAccountId();
}

abstract interface class PendingRevocationStorage {
  Future<void> savePendingRevocationAccountId(String accountId);

  Future<String?> readPendingRevocationAccountId();

  Future<void> clearPendingRevocationAccountId();
}

abstract interface class ConditionalPendingRevocationStorage {
  Future<bool> clearPendingRevocationAccountIdIfMatches(
    String expectedAccountId,
  );
}

final class AppSecureStorage
    implements
        TokenStorage,
        ConditionalTokenStorage,
        AuthTokenTransactionStorage,
        OfflineDatabaseKeyStorage,
        AuthenticatedAccountStorage,
        PendingRevocationStorage,
        ConditionalPendingRevocationStorage {
  const AppSecureStorage({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String kAccessTokenKey = 'access_token';
  static const String kOfflineDatabaseKey = 'offline_database_key';
  static const String kAuthenticatedAccountIdKey = 'authenticated_account_id';
  static const String kPendingRevocationAccountIdKey =
      'pending_revocation_account_id';

  final FlutterSecureStorage _storage;

  @override
  Future<void> saveAccessToken(String token) =>
      saveAccessTokenForOwner(token: token, ownerId: const Uuid().v4());

  @override
  Future<void> saveAccessTokenForOwner({
    required String token,
    required String ownerId,
  }) => _SecureStorageKeyMutex.run(
    kAccessTokenKey,
    () => _storage.write(
      key: kAccessTokenKey,
      value: jsonEncode({'version': 1, 'token': token, 'owner_id': ownerId}),
    ),
  );

  @override
  Future<String?> readAccessToken() async {
    final raw = await _storage.read(key: kAccessTokenKey);
    return raw == null ? null : _decodeAccessTokenRecord(raw).token;
  }

  @override
  Future<void> clearAccessToken() => _SecureStorageKeyMutex.run(
    kAccessTokenKey,
    () => _storage.delete(key: kAccessTokenKey),
  );

  @override
  Future<bool> clearAccessTokenIfMatches(String expectedToken) =>
      _SecureStorageKeyMutex.run(kAccessTokenKey, () async {
        final raw = await _storage.read(key: kAccessTokenKey);
        if (raw == null ||
            _decodeAccessTokenRecord(raw).token != expectedToken) {
          return false;
        }
        await _storage.delete(key: kAccessTokenKey);
        return true;
      });

  @override
  Future<bool> clearAccessTokenForOwner(String ownerId) =>
      _SecureStorageKeyMutex.run(kAccessTokenKey, () async {
        final raw = await _storage.read(key: kAccessTokenKey);
        if (raw == null || _decodeAccessTokenRecord(raw).ownerId != ownerId) {
          return false;
        }
        await _storage.delete(key: kAccessTokenKey);
        return true;
      });

  @override
  Future<void> saveOfflineDatabaseKey(String key) {
    return _storage.write(key: kOfflineDatabaseKey, value: key);
  }

  @override
  Future<String?> readOfflineDatabaseKey() {
    return _storage.read(key: kOfflineDatabaseKey);
  }

  @override
  Future<void> saveAuthenticatedAccountId(String accountId) {
    return _storage.write(key: kAuthenticatedAccountIdKey, value: accountId);
  }

  @override
  Future<String?> readAuthenticatedAccountId() {
    return _storage.read(key: kAuthenticatedAccountIdKey);
  }

  @override
  Future<void> clearAuthenticatedAccountId() {
    return _storage.delete(key: kAuthenticatedAccountIdKey);
  }

  @override
  Future<void> savePendingRevocationAccountId(String accountId) =>
      _SecureStorageKeyMutex.run(
        kPendingRevocationAccountIdKey,
        () => _storage.write(
          key: kPendingRevocationAccountIdKey,
          value: accountId,
        ),
      );

  @override
  Future<String?> readPendingRevocationAccountId() {
    return _storage.read(key: kPendingRevocationAccountIdKey);
  }

  @override
  Future<void> clearPendingRevocationAccountId() => _SecureStorageKeyMutex.run(
    kPendingRevocationAccountIdKey,
    () => _storage.delete(key: kPendingRevocationAccountIdKey),
  );

  @override
  Future<bool> clearPendingRevocationAccountIdIfMatches(
    String expectedAccountId,
  ) => _SecureStorageKeyMutex.run(kPendingRevocationAccountIdKey, () async {
    if (await _storage.read(key: kPendingRevocationAccountIdKey) !=
        expectedAccountId) {
      return false;
    }
    await _storage.delete(key: kPendingRevocationAccountIdKey);
    return true;
  });
}

final class _AccessTokenRecord {
  const _AccessTokenRecord({required this.token, this.ownerId});

  final String token;
  final String? ownerId;
}

_AccessTokenRecord _decodeAccessTokenRecord(String raw) {
  if (!raw.trimLeft().startsWith('{')) {
    return _AccessTokenRecord(token: raw);
  }
  final decoded = jsonDecode(raw);
  if (decoded is! Map || decoded['version'] != 1) {
    throw const FormatException('Unsupported access token record.');
  }
  final token = decoded['token'];
  final ownerId = decoded['owner_id'];
  if (token is! String || ownerId is! String || ownerId.isEmpty) {
    throw const FormatException('Invalid access token record.');
  }
  return _AccessTokenRecord(token: token, ownerId: ownerId);
}

abstract final class _SecureStorageKeyMutex {
  static final Map<String, Future<void>> _tails = {};

  static Future<T> run<T>(String key, Future<T> Function() operation) {
    final previous = _tails[key] ?? Future<void>.value();
    final released = Completer<void>();
    _tails[key] = released.future;
    return previous.catchError((Object _) {}).then((_) async {
      try {
        return await operation();
      } finally {
        released.complete();
        if (identical(_tails[key], released.future)) _tails.remove(key);
      }
    });
  }
}
