import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

enum BiometricCredentialPolicy { disabled, requireUnlock }

final class DeviceCredential {
  const DeviceCredential({
    required this.accessToken,
    required this.refreshToken,
    required this.accountId,
    required this.sessionId,
    required this.accessExpiresAt,
    required this.refreshExpiresAt,
    required this.tokenVersion,
    required this.generation,
    required this.biometricPolicy,
  });

  final String accessToken;
  final String refreshToken;
  final String accountId;
  final String sessionId;
  final DateTime accessExpiresAt;
  final DateTime refreshExpiresAt;
  final int tokenVersion;
  final int generation;
  final BiometricCredentialPolicy biometricPolicy;
}

sealed class CredentialRestoreException implements Exception {
  const CredentialRestoreException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class MalformedCredentialRecordException
    extends CredentialRestoreException {
  const MalformedCredentialRecordException()
    : super('Malformed device credential record.');
}

final class UnsupportedCredentialRecordException
    extends CredentialRestoreException {
  const UnsupportedCredentialRecordException()
    : super('Unsupported device credential record.');
}

abstract interface class DeviceCredentialStorage {
  Future<DeviceCredential?> readDeviceCredential();

  Future<bool> savePendingDeviceCredentialForOwner({
    required DeviceCredential credential,
    required String ownerId,
    required int attemptVersion,
  });

  Future<bool> rotateDeviceCredential({
    required DeviceCredential credential,
    required String expectedAccountId,
    required String expectedSessionId,
    required int expectedGeneration,
  });

  Future<bool> clearDeviceCredentialIfMatches({
    required String accountId,
    required String sessionId,
    required int generation,
  });
}

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
    int? authEpoch,
  });

  Future<bool> clearAuthenticatedAccountProjection({
    required String ownerId,
    required int attemptVersion,
  });
}

abstract interface class ConditionalAuthenticatedAccountStorage {
  Future<bool> clearAuthenticatedAccountIfMatches({
    required String accountId,
    required int authEpoch,
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
        ConditionalAuthenticatedAccountStorage,
        PendingRevocationStorage,
        ConditionalPendingRevocationStorage,
        DeviceCredentialStorage {
  const AppSecureStorage({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String kAccessTokenKey = 'access_token';
  static const String kDeviceCredentialKey = 'device_credential_v3';
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
        final deviceRecord = await _readDeviceCredentialStoreRecord();
        final nextVersion =
            (record.latestAttemptVersion > deviceRecord.latestAttemptVersion
                ? record.latestAttemptVersion
                : deviceRecord.latestAttemptVersion) +
            1;
        await _writeAccessTokenStoreRecord(
          _AccessTokenStoreRecord(
            latestAttemptVersion: nextVersion,
            credential: record.credential,
          ),
        );
        if (deviceRecord.ownerId != null) {
          await _writeDeviceCredentialStoreRecord(
            deviceRecord.copyWith(latestAttemptVersion: nextVersion),
          );
        }
        return nextVersion;
      });

  @override
  Future<bool> savePendingDeviceCredentialForOwner({
    required DeviceCredential credential,
    required String ownerId,
    required int attemptVersion,
  }) => _SecureStorageKeyMutex.run(kAccessTokenKey, () async {
    _validateDeviceCredential(credential);
    if (ownerId.isEmpty || attemptVersion < 1) return false;
    final tokenRecord = await _readAccessTokenStoreRecord();
    final deviceRecord = await _readDeviceCredentialStoreRecord();
    final latest =
        tokenRecord.latestAttemptVersion > deviceRecord.latestAttemptVersion
        ? tokenRecord.latestAttemptVersion
        : deviceRecord.latestAttemptVersion;
    if (latest != attemptVersion) return false;
    await _writeDeviceCredentialStoreRecord(
      _DeviceCredentialStoreRecord(
        latestAttemptVersion: latest,
        state: _AccessTokenState.pending,
        ownerId: ownerId,
        attemptVersion: attemptVersion,
        credential: credential,
      ),
    );
    await _writeAccessTokenStoreRecord(
      _AccessTokenStoreRecord(latestAttemptVersion: latest),
    );
    return true;
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
    try {
      final deviceRecord = await _readDeviceCredentialStoreRecord();
      if (deviceRecord.migrated) {
        await _SecureStorageKeyMutex.run(
          kAccessTokenKey,
          () => _writeDeviceCredentialStoreRecord(
            deviceRecord.copyWith(migrated: false),
          ),
        );
      }
      if (deviceRecord.credential != null) {
        return deviceRecord.state == _AccessTokenState.committed
            ? deviceRecord.credential?.accessToken
            : null;
      }
    } on CredentialRestoreException {
      await _clearUnsafeCredentialRecords();
      rethrow;
    }
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
    final deviceRecord = await _readDeviceCredentialStoreRecord();
    if (deviceRecord.ownerId == ownerId &&
        deviceRecord.attemptVersion == attemptVersion &&
        deviceRecord.latestAttemptVersion == attemptVersion &&
        deviceRecord.credential != null) {
      if (deviceRecord.state != _AccessTokenState.committed) {
        await _writeDeviceCredentialStoreRecord(
          deviceRecord.copyWith(state: _AccessTokenState.committed),
        );
      }
      await _storage.delete(key: kAccessTokenKey);
      return true;
    }
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
        await _storage.delete(key: kDeviceCredentialKey);
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
        final deviceRecord = await _readDeviceCredentialStoreRecord();
        if (deviceRecord.credential?.accessToken == expectedToken) {
          await _storage.delete(key: kDeviceCredentialKey);
          return true;
        }
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
    final deviceRecord = await _readDeviceCredentialStoreRecord();
    if (deviceRecord.ownerId == ownerId &&
        deviceRecord.attemptVersion == attemptVersion) {
      await _storage.delete(key: kDeviceCredentialKey);
      return true;
    }
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
        final deviceRecord = await _readDeviceCredentialStoreRecord();
        if (deviceRecord.state == _AccessTokenState.pending) {
          await _storage.delete(key: kDeviceCredentialKey);
          return true;
        }
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
  Future<DeviceCredential?> readDeviceCredential() async {
    try {
      final record = await _readDeviceCredentialStoreRecord();
      if (record.migrated) {
        await _SecureStorageKeyMutex.run(
          kAccessTokenKey,
          () => _writeDeviceCredentialStoreRecord(
            record.copyWith(migrated: false),
          ),
        );
      }
      return record.state == _AccessTokenState.committed
          ? record.credential
          : null;
    } on CredentialRestoreException {
      await _clearUnsafeCredentialRecords();
      rethrow;
    }
  }

  Future<void> _clearUnsafeCredentialRecords() async {
    await _storage.delete(key: kDeviceCredentialKey);
    await _storage.delete(key: kAccessTokenKey);
  }

  @override
  Future<bool> rotateDeviceCredential({
    required DeviceCredential credential,
    required String expectedAccountId,
    required String expectedSessionId,
    required int expectedGeneration,
  }) => _SecureStorageKeyMutex.run(kAccessTokenKey, () async {
    _validateDeviceCredential(credential);
    final record = await _readDeviceCredentialStoreRecord();
    final current = record.state == _AccessTokenState.committed
        ? record.credential
        : null;
    if (current == null ||
        current.accountId != expectedAccountId ||
        current.sessionId != expectedSessionId ||
        current.generation != expectedGeneration ||
        credential.accountId != expectedAccountId ||
        credential.sessionId != expectedSessionId ||
        credential.generation != expectedGeneration + 1) {
      return false;
    }
    await _writeDeviceCredentialStoreRecord(
      record.copyWith(
        state: _AccessTokenState.committed,
        credential: credential,
      ),
    );
    return true;
  });

  @override
  Future<bool> clearDeviceCredentialIfMatches({
    required String accountId,
    required String sessionId,
    required int generation,
  }) => _SecureStorageKeyMutex.run(kAccessTokenKey, () async {
    final record = await _readDeviceCredentialStoreRecord();
    final current = record.credential;
    if (current?.accountId != accountId ||
        current?.sessionId != sessionId ||
        current?.generation != generation) {
      return false;
    }
    await _storage.delete(key: kDeviceCredentialKey);
    return true;
  });

  Future<_DeviceCredentialStoreRecord>
  _readDeviceCredentialStoreRecord() async {
    final raw = await _storage.read(key: kDeviceCredentialKey);
    if (raw == null) {
      return const _DeviceCredentialStoreRecord(latestAttemptVersion: 0);
    }
    return _decodeDeviceCredentialStoreRecord(raw);
  }

  Future<void> _writeDeviceCredentialStoreRecord(
    _DeviceCredentialStoreRecord record,
  ) => _storage.write(
    key: kDeviceCredentialKey,
    value: _encodeDeviceCredentialStoreRecord(record),
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
    int? authEpoch,
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
        'version': authEpoch == null ? 2 : 3,
        'account_id': accountId,
        'owner_id': ownerId,
        'attempt_version': attemptVersion,
        'auth_epoch': ?authEpoch,
      }),
    );
    return true;
  });

  @override
  Future<String?> readAuthenticatedAccountId() {
    return readDeviceCredential().then((credential) async {
      if (credential != null) return credential.accountId;
      final raw = await _storage.read(key: kAuthenticatedAccountIdKey);
      if (raw == null || !raw.trimLeft().startsWith('{')) return raw;
      final decoded = jsonDecode(raw);
      if (decoded is! Map ||
          (decoded['version'] != 1 &&
              decoded['version'] != 2 &&
              decoded['version'] != 3) ||
          decoded['account_id'] is! String ||
          (decoded['version'] == 1 && decoded['projection_id'] is! String) ||
          ((decoded['version'] == 2 || decoded['version'] == 3) &&
              (decoded['owner_id'] is! String ||
                  decoded['attempt_version'] is! int)) ||
          (decoded['version'] == 3 && decoded['auth_epoch'] is! int)) {
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
  Future<bool> clearAuthenticatedAccountIfMatches({
    required String accountId,
    required int authEpoch,
  }) => _SecureStorageKeyMutex.run(kAuthenticatedAccountIdKey, () async {
    final raw = await _storage.read(key: kAuthenticatedAccountIdKey);
    if (raw == null || !raw.trimLeft().startsWith('{')) return false;
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['version'] != 3 ||
        decoded['account_id'] != accountId ||
        decoded['auth_epoch'] != authEpoch) {
      return false;
    }
    await _storage.delete(key: kAuthenticatedAccountIdKey);
    return true;
  });

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

final class _DeviceCredentialStoreRecord {
  const _DeviceCredentialStoreRecord({
    required this.latestAttemptVersion,
    this.state,
    this.ownerId,
    this.attemptVersion,
    this.credential,
    this.migrated = false,
  });

  final int latestAttemptVersion;
  final _AccessTokenState? state;
  final String? ownerId;
  final int? attemptVersion;
  final DeviceCredential? credential;
  final bool migrated;

  _DeviceCredentialStoreRecord copyWith({
    int? latestAttemptVersion,
    _AccessTokenState? state,
    DeviceCredential? credential,
    bool? migrated,
  }) => _DeviceCredentialStoreRecord(
    latestAttemptVersion: latestAttemptVersion ?? this.latestAttemptVersion,
    state: state ?? this.state,
    ownerId: ownerId,
    attemptVersion: attemptVersion,
    credential: credential ?? this.credential,
    migrated: migrated ?? this.migrated,
  );
}

String _encodeDeviceCredentialStoreRecord(_DeviceCredentialStoreRecord record) {
  final credential = record.credential;
  if (credential == null ||
      record.state == null ||
      record.ownerId == null ||
      record.attemptVersion == null) {
    throw const MalformedCredentialRecordException();
  }
  return jsonEncode({
    'version': 3,
    'state': record.state!.name,
    'owner_id': record.ownerId,
    'attempt_version': record.attemptVersion,
    'latest_attempt_version': record.latestAttemptVersion,
    'access_token': credential.accessToken,
    'refresh_token': credential.refreshToken,
    'account_id': credential.accountId,
    'session_id': credential.sessionId,
    'access_expires_at': credential.accessExpiresAt.toUtc().toIso8601String(),
    'refresh_expires_at': credential.refreshExpiresAt.toUtc().toIso8601String(),
    'token_version': credential.tokenVersion,
    'generation': credential.generation,
    'biometric_policy': credential.biometricPolicy.name,
  });
}

_DeviceCredentialStoreRecord _decodeDeviceCredentialStoreRecord(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    throw const MalformedCredentialRecordException();
  }
  if (decoded is! Map) {
    throw const MalformedCredentialRecordException();
  }
  final version = decoded['version'];
  if (version != 2 && version != 3) {
    throw const UnsupportedCredentialRecordException();
  }
  final expectedKeys = <String>{
    'version',
    'state',
    'owner_id',
    'attempt_version',
    'latest_attempt_version',
    'access_token',
    'refresh_token',
    'account_id',
    'session_id',
    'access_expires_at',
    'refresh_expires_at',
    'token_version',
    'generation',
    if (version == 3) 'biometric_policy',
  };
  if (decoded.keys.any(
        (key) => key is! String || !expectedKeys.contains(key),
      ) ||
      decoded.length != expectedKeys.length) {
    throw const MalformedCredentialRecordException();
  }
  final state = switch (decoded['state']) {
    'pending' => _AccessTokenState.pending,
    'committed' => _AccessTokenState.committed,
    _ => throw const MalformedCredentialRecordException(),
  };
  final ownerId = decoded['owner_id'];
  final attemptVersion = decoded['attempt_version'];
  final latestAttemptVersion = decoded['latest_attempt_version'];
  final accessToken = decoded['access_token'];
  final refreshToken = decoded['refresh_token'];
  final accountId = decoded['account_id'];
  final sessionId = decoded['session_id'];
  final tokenVersion = decoded['token_version'];
  final generation = decoded['generation'];
  if (ownerId is! String ||
      ownerId.isEmpty ||
      attemptVersion is! int ||
      attemptVersion < 1 ||
      latestAttemptVersion is! int ||
      latestAttemptVersion < attemptVersion ||
      accessToken is! String ||
      refreshToken is! String ||
      accountId is! String ||
      sessionId is! String ||
      tokenVersion is! int ||
      generation is! int) {
    throw const MalformedCredentialRecordException();
  }
  final accessExpiresAt = _parseCredentialDate(decoded['access_expires_at']);
  final refreshExpiresAt = _parseCredentialDate(decoded['refresh_expires_at']);
  final biometricPolicy = version == 2
      ? BiometricCredentialPolicy.disabled
      : switch (decoded['biometric_policy']) {
          'disabled' => BiometricCredentialPolicy.disabled,
          'requireUnlock' => BiometricCredentialPolicy.requireUnlock,
          _ => throw const MalformedCredentialRecordException(),
        };
  final credential = DeviceCredential(
    accessToken: accessToken,
    refreshToken: refreshToken,
    accountId: accountId,
    sessionId: sessionId,
    accessExpiresAt: accessExpiresAt,
    refreshExpiresAt: refreshExpiresAt,
    tokenVersion: tokenVersion,
    generation: generation,
    biometricPolicy: biometricPolicy,
  );
  _validateDeviceCredential(credential);
  return _DeviceCredentialStoreRecord(
    latestAttemptVersion: latestAttemptVersion,
    state: state,
    ownerId: ownerId,
    attemptVersion: attemptVersion,
    credential: credential,
    migrated: version == 2,
  );
}

DateTime _parseCredentialDate(Object? value) {
  if (value is! String) throw const MalformedCredentialRecordException();
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc) {
    throw const MalformedCredentialRecordException();
  }
  return parsed;
}

void _validateDeviceCredential(DeviceCredential credential) {
  if (credential.accessToken.trim().isEmpty ||
      credential.refreshToken.trim().isEmpty ||
      credential.accountId.trim().isEmpty ||
      credential.sessionId.trim().isEmpty ||
      credential.tokenVersion < 1 ||
      credential.generation < 1 ||
      !credential.accessExpiresAt.isUtc ||
      !credential.refreshExpiresAt.isUtc ||
      !credential.refreshExpiresAt.isAfter(credential.accessExpiresAt)) {
    throw const MalformedCredentialRecordException();
  }
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
