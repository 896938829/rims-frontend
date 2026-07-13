import 'dart:convert';

import '../entities/scan_data.dart';
import 'scan_lookup_cache.dart';
import '../../../offline/domain/services/offline_ownership_service.dart';
import '../../../offline/domain/services/offline_write_barrier.dart';

final class ScanSessionSnapshot {
  const ScanSessionSnapshot({required this.mode, required this.lines});

  final ScanMode mode;
  final List<ScanLine> lines;
}

final class ScanSessionStore implements OfflineOwnedScanStore {
  ScanSessionStore({AsyncScanStorage? storage, this.writeBarrier})
    : storage = storage ?? SharedPreferencesAsyncScanStorage();

  static const int schemaVersion = 1;
  static const String _keyPrefix = 'rims.scanner.session.v1.';

  final AsyncScanStorage storage;
  final OfflineWriteBarrier? writeBarrier;

  static String storageKey({required String userId, required int warehouseId}) {
    return '$_keyPrefix${Uri.encodeComponent(userId)}.$warehouseId';
  }

  Future<void> save({
    required String userId,
    required int warehouseId,
    required ScanSessionSnapshot session,
  }) => _protect(userId, () {
    final value = jsonEncode(<String, Object?>{
      'schemaVersion': schemaVersion,
      'userId': userId,
      'warehouseId': warehouseId,
      'mode': session.mode.name,
      'lines': session.lines.map((line) {
        return <String, Object?>{
          'product': ScanProductIdentity.fromInventoryItem(line.item).toJson(),
          'quantity': line.quantity,
        };
      }).toList(),
    });
    return storage.write(
      storageKey(userId: userId, warehouseId: warehouseId),
      value,
    );
  });

  Future<ScanSessionSnapshot?> restore({
    required String userId,
    required int warehouseId,
  }) => _protect(userId, () async {
    final key = storageKey(userId: userId, warehouseId: warehouseId);
    final raw = await storage.read(key);
    if (raw == null) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?> ||
          decoded['schemaVersion'] != schemaVersion ||
          decoded['userId'] != userId ||
          decoded['warehouseId'] != warehouseId) {
        throw const FormatException('Session schema or ownership mismatch.');
      }
      final modeName = decoded['mode'];
      final rawLines = decoded['lines'];
      if (modeName is! String || rawLines is! List<Object?>) {
        throw const FormatException('Invalid scan session.');
      }
      final mode = ScanMode.values.firstWhere(
        (value) => value.name == modeName,
      );
      final lines = rawLines.map((rawLine) {
        if (rawLine is! Map<String, Object?>) {
          throw const FormatException('Session line must be an object.');
        }
        final rawProduct = rawLine['product'];
        final quantity = rawLine['quantity'];
        if (rawProduct is! Map<String, Object?> ||
            quantity is! int ||
            quantity < 1) {
          throw const FormatException('Invalid session line.');
        }
        final identity = ScanProductIdentity.fromJson(rawProduct);
        return ScanLine(
          item: identity.toNonAuthoritativeItem(),
          quantity: quantity,
          isStale: true,
        );
      }).toList();
      return ScanSessionSnapshot(mode: mode, lines: List.unmodifiable(lines));
    } on Object {
      await storage.delete(key);
      return null;
    }
  });

  Future<void> clear({required String userId, required int warehouseId}) {
    return _protect(
      userId,
      () =>
          storage.delete(storageKey(userId: userId, warehouseId: warehouseId)),
    );
  }

  Future<void> clearForUser(String userId) =>
      _protect(userId, () => _clearForUser(userId));

  Future<void> _clearForUser(String userId) async {
    final prefix = '$_keyPrefix${Uri.encodeComponent(userId)}.';
    final matchingKeys = await storage.keys(prefix: prefix);
    await Future.wait(matchingKeys.map(storage.delete));
  }

  @override
  Future<int> countForAccount(String accountId) async {
    final prefix = '$_keyPrefix${Uri.encodeComponent(accountId)}.';
    return (await storage.keys(prefix: prefix)).length;
  }

  Future<Set<String>> contentIdentitiesForAccount(String accountId) async {
    final prefix = '$_keyPrefix${Uri.encodeComponent(accountId)}.';
    final keys = await storage.keys(prefix: prefix);
    final identities = <String>{};
    for (final key in keys) {
      identities.add('scan-session:$key:${await storage.read(key) ?? ''}');
    }
    return identities;
  }

  @override
  Future<void> clearForAccount(String accountId) => _clearForUser(accountId);

  @override
  Future<void> clearAll() async {
    final matchingKeys = await storage.keys(prefix: _keyPrefix);
    await Future.wait(matchingKeys.map(storage.delete));
  }

  Future<T> _protect<T>(String accountId, Future<T> Function() operation) {
    final barrier = writeBarrier;
    return barrier == null
        ? Future<T>.sync(operation)
        : barrier.protect(accountId: accountId, operation: operation);
  }
}
