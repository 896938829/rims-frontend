import 'dart:io';
import 'dart:math';

import 'offline_database.dart';

typedef ReadOfflineDatabaseKey = Future<String?> Function();
typedef WriteOfflineDatabaseKey = Future<void> Function(String value);
typedef SecureRandomBytes = List<int> Function();

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
    final bytes = _randomBytes();
    if (bytes.length != 32 || bytes.any((value) => value < 0 || value > 255)) {
      throw StateError('Offline database key source must return 32 bytes.');
    }
    final key = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
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

  static List<int> _secureRandomBytes() {
    final random = Random.secure();
    return List<int>.generate(32, (_) => random.nextInt(256));
  }
}
