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
  Future<void> savePendingAccessTokenForOwner({
    required String token,
    required String ownerId,
  });

  Future<bool> commitAccessTokenForOwner(String ownerId);

  Future<bool> clearAccessTokenForOwner(String ownerId);

  Future<bool> clearPendingAccessToken();
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
  Future<void> saveAccessToken(String token) => _writeAccessTokenRecord(
    _AccessTokenRecord(
      token: token,
      ownerId: const Uuid().v4(),
      state: _AccessTokenState.committed,
    ),
  );

  @override
  Future<void> savePendingAccessTokenForOwner({
    required String token,
    required String ownerId,
  }) => _writeAccessTokenRecord(
    _AccessTokenRecord(
      token: token,
      ownerId: ownerId,
      state: _AccessTokenState.pending,
    ),
  );

  @override
  Future<String?> readAccessToken() async {
    final raw = await _storage.read(key: kAccessTokenKey);
    if (raw == null) return null;
    final record = _decodeAccessTokenRecord(raw);
    return record.state == _AccessTokenState.committed ? record.token : null;
  }

  @override
  Future<bool> commitAccessTokenForOwner(String ownerId) =>
      _SecureStorageKeyMutex.run(kAccessTokenKey, () async {
        final raw = await _storage.read(key: kAccessTokenKey);
        if (raw == null) return false;
        final record = _decodeAccessTokenRecord(raw);
        if (record.ownerId != ownerId) return false;
        if (record.state == _AccessTokenState.committed) return true;
        await _storage.write(
          key: kAccessTokenKey,
          value: _encodeAccessTokenRecord(
            _AccessTokenRecord(
              token: record.token,
              ownerId: ownerId,
              state: _AccessTokenState.committed,
            ),
          ),
        );
        return true;
      });

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
  Future<bool> clearPendingAccessToken() =>
      _SecureStorageKeyMutex.run(kAccessTokenKey, () async {
        final raw = await _storage.read(key: kAccessTokenKey);
        if (raw == null) return false;
        final record = _decodeAccessTokenRecord(raw);
        if (record.state != _AccessTokenState.pending) return false;
        await _storage.delete(key: kAccessTokenKey);
        return true;
      });

  Future<void> _writeAccessTokenRecord(_AccessTokenRecord record) =>
      _SecureStorageKeyMutex.run(
        kAccessTokenKey,
        () => _storage.write(
          key: kAccessTokenKey,
          value: _encodeAccessTokenRecord(record),
        ),
      );

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
  const _AccessTokenRecord({
    required this.token,
    required this.state,
    this.ownerId,
  });

  final String token;
  final String? ownerId;
  final _AccessTokenState state;
}

enum _AccessTokenState { pending, committed }

String _encodeAccessTokenRecord(_AccessTokenRecord record) => jsonEncode({
  'version': 2,
  'state': record.state.name,
  'token': record.token,
  'owner_id': record.ownerId,
});

_AccessTokenRecord _decodeAccessTokenRecord(String raw) {
  if (!raw.trimLeft().startsWith('{')) {
    return _AccessTokenRecord(token: raw, state: _AccessTokenState.committed);
  }
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('Unsupported access token record.');
  }
  final version = decoded['version'];
  final token = decoded['token'];
  final ownerId = decoded['owner_id'];
  if (token is! String || ownerId is! String || ownerId.isEmpty) {
    throw const FormatException('Invalid access token record.');
  }
  if (version == 1) {
    return _AccessTokenRecord(
      token: token,
      ownerId: ownerId,
      state: _AccessTokenState.committed,
    );
  }
  if (version != 2) {
    throw const FormatException('Unsupported access token record.');
  }
  final state = switch (decoded['state']) {
    'pending' => _AccessTokenState.pending,
    'committed' => _AccessTokenState.committed,
    _ => throw const FormatException('Invalid access token record.'),
  };
  return _AccessTokenRecord(token: token, ownerId: ownerId, state: state);
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
