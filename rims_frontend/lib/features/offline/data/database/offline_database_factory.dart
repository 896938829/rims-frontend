import 'dart:io';
import 'dart:math';

import 'offline_database.dart';
import '../../domain/services/offline_ownership_service.dart';

typedef ReadOfflineDatabaseKey = Future<String?> Function();
typedef WriteOfflineDatabaseKey = Future<void> Function(String value);
typedef SecureRandomBytes = List<int> Function();
typedef RekeyOfflineDatabase = Future<void> Function(String value);

final class OfflineDatabaseFactory {
  OfflineDatabaseFactory({
    required this.readKey,
    required this.writeKey,
    SecureRandomBytes? randomBytes,
    DateTime Function()? now,
  }) : _randomBytes = randomBytes ?? _secureRandomBytes,
       _now = now ?? DateTime.now;

  final ReadOfflineDatabaseKey readKey;
  final WriteOfflineDatabaseKey writeKey;
  final SecureRandomBytes _randomBytes;
  final DateTime Function() _now;

  Future<String> loadOrCreateKey() async {
    final existing = await readKey();
    if (existing != null) {
      if (!_isValidKey(existing)) {
        throw StateError('Offline database key is invalid.');
      }
      return existing;
    }
    final key = _createKey(_randomBytes());
    await writeKey(key);
    return key;
  }

  Future<OfflineDatabase> openNative(String path) async {
    final key = await loadOrCreateKey();
    final file = File(path);
    try {
      return await _openAndVerify(path, key);
    } on Object {
      if (!await file.exists()) rethrow;
      final quarantine =
          '$path.corrupt-${_now().toUtc().millisecondsSinceEpoch}';
      await file.rename(quarantine);
      return _openAndVerify(path, key);
    }
  }

  Future<OfflineDatabase> _openAndVerify(String path, String key) async {
    final database = OfflineDatabase.native(
      encryptionKey: key,
      databasePath: path,
    );
    try {
      await database.customSelect('PRAGMA user_version').get();
      return database;
    } on Object {
      try {
        await database.close();
      } on Object {
        // Preserve the original open failure.
      }
      rethrow;
    }
  }

  static bool _isValidKey(String value) {
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
  }

  static String _createKey(List<int> bytes) {
    if (bytes.length != 32 || bytes.any((value) => value < 0 || value > 255)) {
      throw StateError('Offline database key source must return 32 bytes.');
    }
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  static List<int> _secureRandomBytes() {
    final random = Random.secure();
    return List<int>.generate(32, (_) => random.nextInt(256));
  }
}

final class OfflineDatabaseKeyRotator implements OfflineDatabaseKeyManager {
  OfflineDatabaseKeyRotator({
    required this.readKey,
    required this.writeKey,
    required this.rekey,
    SecureRandomBytes? randomBytes,
  }) : _randomBytes = randomBytes ?? OfflineDatabaseFactory._secureRandomBytes;

  final ReadOfflineDatabaseKey readKey;
  final WriteOfflineDatabaseKey writeKey;
  final RekeyOfflineDatabase rekey;
  final SecureRandomBytes _randomBytes;

  @override
  Future<void> rotateAfterRevocation() async {
    final previous = await readKey();
    if (previous == null || !OfflineDatabaseFactory._isValidKey(previous)) {
      throw StateError('Offline database key is unavailable for rotation.');
    }
    final next = OfflineDatabaseFactory._createKey(_randomBytes());
    if (next == previous) {
      throw StateError('Offline database key rotation produced the same key.');
    }

    await rekey(next);
    try {
      await writeKey(next);
    } on Object catch (writeError, writeStackTrace) {
      try {
        await rekey(previous);
      } on Object catch (rollbackError) {
        Error.throwWithStackTrace(
          StateError(
            'Offline database key persistence and rollback both failed: '
            '${rollbackError.runtimeType}.',
          ),
          writeStackTrace,
        );
      }
      Error.throwWithStackTrace(writeError, writeStackTrace);
    }
  }
}
