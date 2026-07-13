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
  Future<int> beginAccessTokenAttempt(String ownerId);

  Future<bool> savePendingAccessTokenForOwner({
    required String token,
    required String ownerId,
    required int attemptVersion,
  });

  Future<bool> commitAccessTokenForOwner(
    String ownerId, {
    required int attemptVersion,
  });

  Future<bool> clearAccessTokenForOwner(
    String ownerId, {
    required int attemptVersion,
  });

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

abstract interface class AuthenticatedAccountTransactionStorage {
  Future<bool> saveAuthenticatedAccountProjection({
    required String accountId,
    required String ownerId,
    required int attemptVersion,
  });

  Future<bool> clearAuthenticatedAccountProjection({
    required String ownerId,
    required int attemptVersion,
  });
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
        AuthenticatedAccountTransactionStorage,
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
  Future<void> saveAccessToken(String token) async {
    final ownerId = const Uuid().v4();
    final attemptVersion = await beginAccessTokenAttempt(ownerId);
    final published = await savePendingAccessTokenForOwner(
      token: token,
      ownerId: ownerId,
      attemptVersion: attemptVersion,
    );
    final committed =
        published &&
        await commitAccessTokenForOwner(
          ownerId,
          attemptVersion: attemptVersion,
        );
    if (!committed) {
      throw StateError('Access token transaction was superseded.');
    }
  }

  @override
  Future<int> beginAccessTokenAttempt(String ownerId) =>
      _SecureStorageKeyMutex.run(kAccessTokenKey, () async {
        final record = await _readAccessTokenStoreRecord();
        final nextVersion = record.latestAttemptVersion + 1;
        await _writeAccessTokenStoreRecord(
          _AccessTokenStoreRecord(
            latestAttemptVersion: nextVersion,
            credential: record.credential,
          ),
        );
        return nextVersion;
      });

  @override
  Future<bool> savePendingAccessTokenForOwner({
    required String token,
    required String ownerId,
    required int attemptVersion,
  }) => _SecureStorageKeyMutex.run(kAccessTokenKey, () async {
    final record = await _readAccessTokenStoreRecord();
    if (record.latestAttemptVersion != attemptVersion) return false;
    await _writeAccessTokenStoreRecord(
      _AccessTokenStoreRecord(
        latestAttemptVersion: record.latestAttemptVersion,
        credential: _AccessTokenCredential(
          token: token,
          ownerId: ownerId,
          attemptVersion: attemptVersion,
          state: _AccessTokenState.pending,
        ),
      ),
    );
    return true;
  });

  @override
  Future<String?> readAccessToken() async {
    final raw = await _storage.read(key: kAccessTokenKey);
    if (raw == null) return null;
    final credential = _decodeAccessTokenStoreRecord(raw).credential;
    return credential?.state == _AccessTokenState.committed
        ? credential?.token
        : null;
  }

  @override
  Future<bool> commitAccessTokenForOwner(
    String ownerId, {
    required int attemptVersion,
  }) => _SecureStorageKeyMutex.run(kAccessTokenKey, () async {
    final record = await _readAccessTokenStoreRecord();
    final credential = record.credential;
    if (record.latestAttemptVersion != attemptVersion ||
        credential?.ownerId != ownerId ||
        credential?.attemptVersion != attemptVersion) {
      return false;
    }
    if (credential?.state == _AccessTokenState.committed) return true;
    await _writeAccessTokenStoreRecord(
      _AccessTokenStoreRecord(
        latestAttemptVersion: record.latestAttemptVersion,
        credential: _AccessTokenCredential(
          token: credential!.token,
          ownerId: ownerId,
          attemptVersion: attemptVersion,
          state: _AccessTokenState.committed,
        ),
      ),
    );
    return true;
  });

  @override
  Future<void> clearAccessToken() =>
      _SecureStorageKeyMutex.run(kAccessTokenKey, () async {
        final record = await _readAccessTokenStoreRecord();
        await _writeAccessTokenStoreRecord(
          _AccessTokenStoreRecord(
            latestAttemptVersion: record.latestAttemptVersion,
          ),
        );
      });

  @override
  Future<bool> clearAccessTokenIfMatches(String expectedToken) =>
      _SecureStorageKeyMutex.run(kAccessTokenKey, () async {
        final record = await _readAccessTokenStoreRecord();
        if (record.credential?.token != expectedToken) {
          return false;
        }
        await _writeAccessTokenStoreRecord(
          _AccessTokenStoreRecord(
            latestAttemptVersion: record.latestAttemptVersion,
          ),
        );
        return true;
      });

  @override
  Future<bool> clearAccessTokenForOwner(
    String ownerId, {
    required int attemptVersion,
  }) => _SecureStorageKeyMutex.run(kAccessTokenKey, () async {
    final record = await _readAccessTokenStoreRecord();
    final credential = record.credential;
    if (credential?.ownerId != ownerId ||
        credential?.attemptVersion != attemptVersion) {
      return false;
    }
    await _writeAccessTokenStoreRecord(
      _AccessTokenStoreRecord(
        latestAttemptVersion: record.latestAttemptVersion,
      ),
    );
    return true;
  });

  @override
  Future<bool> clearPendingAccessToken() =>
      _SecureStorageKeyMutex.run(kAccessTokenKey, () async {
        final record = await _readAccessTokenStoreRecord();
        if (record.credential?.state != _AccessTokenState.pending) return false;
        await _writeAccessTokenStoreRecord(
          _AccessTokenStoreRecord(
            latestAttemptVersion: record.latestAttemptVersion,
          ),
        );
        return true;
      });

  Future<_AccessTokenStoreRecord> _readAccessTokenStoreRecord() async {
    final raw = await _storage.read(key: kAccessTokenKey);
    return raw == null
        ? const _AccessTokenStoreRecord(latestAttemptVersion: 0)
        : _decodeAccessTokenStoreRecord(raw);
  }

  Future<void> _writeAccessTokenStoreRecord(_AccessTokenStoreRecord record) =>
      _storage.write(
        key: kAccessTokenKey,
        value: _encodeAccessTokenStoreRecord(record),
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
  Future<void> saveAuthenticatedAccountId(String accountId) =>
      _SecureStorageKeyMutex.run(
        kAuthenticatedAccountIdKey,
        () => _storage.write(key: kAuthenticatedAccountIdKey, value: accountId),
      );

  @override
  Future<bool> saveAuthenticatedAccountProjection({
    required String accountId,
    required String ownerId,
    required int attemptVersion,
  }) => _SecureStorageKeyMutex.run(kAuthenticatedAccountIdKey, () async {
    final raw = await _storage.read(key: kAuthenticatedAccountIdKey);
    if (raw != null && raw.trimLeft().startsWith('{')) {
      final decoded = jsonDecode(raw);
      final currentVersion = decoded is Map ? decoded['attempt_version'] : null;
      final currentOwner = decoded is Map ? decoded['owner_id'] : null;
      if (currentVersion is int &&
          (currentVersion > attemptVersion ||
              (currentVersion == attemptVersion && currentOwner != ownerId))) {
        return false;
      }
    }
    await _storage.write(
      key: kAuthenticatedAccountIdKey,
      value: jsonEncode({
        'version': 2,
        'account_id': accountId,
        'owner_id': ownerId,
        'attempt_version': attemptVersion,
      }),
    );
    return true;
  });

  @override
  Future<String?> readAuthenticatedAccountId() {
    return _storage.read(key: kAuthenticatedAccountIdKey).then((raw) {
      if (raw == null || !raw.trimLeft().startsWith('{')) return raw;
      final decoded = jsonDecode(raw);
      if (decoded is! Map ||
          (decoded['version'] != 1 && decoded['version'] != 2) ||
          decoded['account_id'] is! String ||
          (decoded['version'] == 1 && decoded['projection_id'] is! String) ||
          (decoded['version'] == 2 &&
              (decoded['owner_id'] is! String ||
                  decoded['attempt_version'] is! int))) {
        throw const FormatException('Invalid authenticated account record.');
      }
      return decoded['account_id']! as String;
    });
  }

  @override
  Future<void> clearAuthenticatedAccountId() => _SecureStorageKeyMutex.run(
    kAuthenticatedAccountIdKey,
    () => _storage.delete(key: kAuthenticatedAccountIdKey),
  );

  @override
  Future<bool> clearAuthenticatedAccountProjection({
    required String ownerId,
    required int attemptVersion,
  }) => _SecureStorageKeyMutex.run(kAuthenticatedAccountIdKey, () async {
    final raw = await _storage.read(key: kAuthenticatedAccountIdKey);
    if (raw == null || !raw.trimLeft().startsWith('{')) return false;
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['owner_id'] != ownerId ||
        decoded['attempt_version'] != attemptVersion) {
      return false;
    }
    await _storage.delete(key: kAuthenticatedAccountIdKey);
    return true;
  });

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

final class _AccessTokenStoreRecord {
  const _AccessTokenStoreRecord({
    required this.latestAttemptVersion,
    this.credential,
  });

  final int latestAttemptVersion;
  final _AccessTokenCredential? credential;
}

final class _AccessTokenCredential {
  const _AccessTokenCredential({
    required this.token,
    required this.state,
    required this.attemptVersion,
    this.ownerId,
  });

  final String token;
  final String? ownerId;
  final _AccessTokenState state;
  final int attemptVersion;
}

enum _AccessTokenState { pending, committed }

String _encodeAccessTokenStoreRecord(_AccessTokenStoreRecord record) {
  final credential = record.credential;
  return jsonEncode({
    'version': 3,
    'latest_attempt_version': record.latestAttemptVersion,
    if (credential != null) ...{
      'state': credential.state.name,
      'token': credential.token,
      'owner_id': credential.ownerId,
      'attempt_version': credential.attemptVersion,
    },
  });
}

_AccessTokenStoreRecord _decodeAccessTokenStoreRecord(String raw) {
  if (!raw.trimLeft().startsWith('{')) {
    return _AccessTokenStoreRecord(
      latestAttemptVersion: 0,
      credential: _AccessTokenCredential(
        token: raw,
        state: _AccessTokenState.committed,
        attemptVersion: 0,
      ),
    );
  }
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('Unsupported access token record.');
  }
  final version = decoded['version'];
  if (version == 3) {
    final latestAttemptVersion = decoded['latest_attempt_version'];
    if (latestAttemptVersion is! int || latestAttemptVersion < 0) {
      throw const FormatException('Invalid access token record.');
    }
    final stateValue = decoded['state'];
    if (stateValue == null) {
      return _AccessTokenStoreRecord(
        latestAttemptVersion: latestAttemptVersion,
      );
    }
    final state = switch (stateValue) {
      'pending' => _AccessTokenState.pending,
      'committed' => _AccessTokenState.committed,
      _ => throw const FormatException('Invalid access token record.'),
    };
    final token = decoded['token'];
    final ownerId = decoded['owner_id'];
    final attemptVersion = decoded['attempt_version'];
    final isLegacyCommitted =
        state == _AccessTokenState.committed &&
        attemptVersion == 0 &&
        (ownerId == null || ownerId is String);
    final isVersionedCredential =
        attemptVersion is int &&
        attemptVersion >= 1 &&
        ownerId is String &&
        ownerId.isNotEmpty;
    if (token is! String ||
        attemptVersion is! int ||
        (!isLegacyCommitted && !isVersionedCredential) ||
        attemptVersion > latestAttemptVersion) {
      throw const FormatException('Invalid access token record.');
    }
    return _AccessTokenStoreRecord(
      latestAttemptVersion: latestAttemptVersion,
      credential: _AccessTokenCredential(
        token: token,
        ownerId: ownerId,
        state: state,
        attemptVersion: attemptVersion,
      ),
    );
  }
  final token = decoded['token'];
  final ownerId = decoded['owner_id'];
  if (token is! String || ownerId is! String || ownerId.isEmpty) {
    throw const FormatException('Invalid access token record.');
  }
  if (version == 1) {
    return _AccessTokenStoreRecord(
      latestAttemptVersion: 0,
      credential: _AccessTokenCredential(
        token: token,
        ownerId: ownerId,
        state: _AccessTokenState.committed,
        attemptVersion: 0,
      ),
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
  return _AccessTokenStoreRecord(
    latestAttemptVersion: 0,
    credential: _AccessTokenCredential(
      token: token,
      ownerId: ownerId,
      state: state,
      attemptVersion: 0,
    ),
  );
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
