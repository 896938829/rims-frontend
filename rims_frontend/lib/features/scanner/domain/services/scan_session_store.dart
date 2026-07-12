import 'dart:convert';

import '../entities/scan_data.dart';
import 'scan_lookup_cache.dart';

final class ScanSessionSnapshot {
  const ScanSessionSnapshot({required this.mode, required this.lines});

  final ScanMode mode;
  final List<ScanLine> lines;
}

final class ScanSessionStore {
  ScanSessionStore({AsyncScanStorage? storage})
    : storage = storage ?? SharedPreferencesAsyncScanStorage();

  static const int schemaVersion = 1;
  static const String _keyPrefix = 'rims.scanner.session.v1.';

  final AsyncScanStorage storage;

  static String storageKey({required String userId, required int warehouseId}) {
    return '$_keyPrefix${Uri.encodeComponent(userId)}.$warehouseId';
  }

  Future<void> save({
    required String userId,
    required int warehouseId,
    required ScanSessionSnapshot session,
  }) {
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
  }

  Future<ScanSessionSnapshot?> restore({
    required String userId,
    required int warehouseId,
  }) async {
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
  }

  Future<void> clear({required String userId, required int warehouseId}) {
    return storage.delete(storageKey(userId: userId, warehouseId: warehouseId));
  }

  Future<void> clearForUser(String userId) async {
    final prefix = '$_keyPrefix${Uri.encodeComponent(userId)}.';
    final matchingKeys = await storage.keys(prefix: prefix);
    await Future.wait(matchingKeys.map(storage.delete));
  }
}
