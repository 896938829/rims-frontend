import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../inventory/domain/entities/inventory_item.dart';
import '../entities/scan_data.dart';

abstract interface class AsyncScanStorage {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  Future<Set<String>> keys({required String prefix});
}

final class SharedPreferencesAsyncScanStorage implements AsyncScanStorage {
  SharedPreferencesAsyncScanStorage([SharedPreferencesAsync? preferences])
    : _preferences = preferences;

  SharedPreferencesAsync? _preferences;

  SharedPreferencesAsync get _delegate {
    return _preferences ??= SharedPreferencesAsync();
  }

  @override
  Future<void> delete(String key) => _delegate.remove(key);

  @override
  Future<Set<String>> keys({required String prefix}) async {
    final allKeys = await _delegate.getKeys();
    return allKeys.where((key) => key.startsWith(prefix)).toSet();
  }

  @override
  Future<String?> read(String key) => _delegate.getString(key);

  @override
  Future<void> write(String key, String value) {
    return _delegate.setString(key, value);
  }
}

final class ScanProductIdentity {
  const ScanProductIdentity({
    required this.inventoryItemId,
    required this.productId,
    required this.productName,
    required this.sku,
    required this.statusLabel,
    required this.imageUrl,
    this.alertThreshold,
    this.status,
    this.retailPrice,
  });

  factory ScanProductIdentity.fromInventoryItem(InventoryItem item) {
    return ScanProductIdentity(
      inventoryItemId: item.id,
      productId: item.productId,
      productName: item.productName,
      sku: item.sku,
      statusLabel: item.statusLabel,
      imageUrl: item.imageUrl,
      alertThreshold: item.alertThreshold,
      status: item.status,
      retailPrice: item.retailPrice,
    );
  }

  factory ScanProductIdentity.fromJson(Map<String, Object?> json) {
    return ScanProductIdentity(
      inventoryItemId: _requiredInt(json, 'inventoryItemId'),
      productId: _requiredInt(json, 'productId'),
      productName: _requiredString(json, 'productName'),
      sku: _requiredString(json, 'sku'),
      statusLabel: _requiredString(json, 'statusLabel'),
      imageUrl: _requiredString(json, 'imageUrl'),
      alertThreshold: _optionalInt(json, 'alertThreshold'),
      status: _optionalInt(json, 'status'),
      retailPrice: _optionalDouble(json, 'retailPrice'),
    );
  }

  final int inventoryItemId;
  final int productId;
  final String productName;
  final String sku;
  final String statusLabel;
  final String imageUrl;
  final int? alertThreshold;
  final int? status;
  final double? retailPrice;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'inventoryItemId': inventoryItemId,
      'productId': productId,
      'productName': productName,
      'sku': sku,
      'statusLabel': statusLabel,
      'imageUrl': imageUrl,
      if (alertThreshold != null) 'alertThreshold': alertThreshold,
      if (status != null) 'status': status,
      if (retailPrice != null) 'retailPrice': retailPrice,
    };
  }

  InventoryItem toNonAuthoritativeItem() {
    return InventoryItem(
      id: inventoryItemId,
      productId: productId,
      productName: productName,
      sku: sku,
      availableQuantity: 0,
      stockQuantity: 0,
      statusLabel: statusLabel,
      imageUrl: imageUrl,
      alertThreshold: alertThreshold,
      status: status,
      retailPrice: retailPrice,
    );
  }
}

final class CachedScanLookup {
  const CachedScanLookup({required this.identity, required this.cachedAt});

  final ScanProductIdentity identity;
  final DateTime cachedAt;

  bool get isStale => true;

  ScanLine toScanLine({int quantity = 1}) {
    return ScanLine(
      item: identity.toNonAuthoritativeItem(),
      quantity: quantity,
      isStale: true,
    );
  }
}

final class ScanLookupCache {
  ScanLookupCache({
    AsyncScanStorage? storage,
    this.ttl = const Duration(hours: 24),
    this.maxEntries = 500,
    DateTime Function()? now,
  }) : storage = storage ?? SharedPreferencesAsyncScanStorage(),
       _now = now ?? DateTime.now;

  static const int schemaVersion = 1;
  static const String _keyPrefix = 'rims.scanner.lookup.v1.';

  final AsyncScanStorage storage;
  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _now;

  static String storageKey({required String userId, required int warehouseId}) {
    return '$_keyPrefix${Uri.encodeComponent(userId)}.$warehouseId';
  }

  Future<void> put({
    required String userId,
    required int warehouseId,
    required String barcode,
    required InventoryItem item,
  }) async {
    final normalizedBarcode = barcode.trim();
    if (normalizedBarcode.isEmpty || maxEntries <= 0) {
      return;
    }

    final envelope = await _readEnvelope(
      userId: userId,
      warehouseId: warehouseId,
    );
    final now = _now().toUtc();
    final entries =
        (envelope?.entries ?? <_LookupEntry>[])
            .where(
              (entry) =>
                  !_isExpired(entry, now) && entry.barcode != normalizedBarcode,
            )
            .toList()
          ..add(
            _LookupEntry(
              barcode: normalizedBarcode,
              product: ScanProductIdentity.fromInventoryItem(item),
              cachedAt: now,
            ),
          )
          ..sort((left, right) => left.cachedAt.compareTo(right.cachedAt));
    if (entries.length > maxEntries) {
      entries.removeRange(0, entries.length - maxEntries);
    }
    await _writeEnvelope(
      userId: userId,
      warehouseId: warehouseId,
      entries: entries,
    );
  }

  Future<CachedScanLookup?> get({
    required String userId,
    required int warehouseId,
    required String barcode,
  }) async {
    final envelope = await _readEnvelope(
      userId: userId,
      warehouseId: warehouseId,
    );
    if (envelope == null) {
      return null;
    }

    final now = _now().toUtc();
    final liveEntries = envelope.entries
        .where((entry) => !_isExpired(entry, now))
        .toList();
    if (liveEntries.length != envelope.entries.length) {
      await _writeEnvelope(
        userId: userId,
        warehouseId: warehouseId,
        entries: liveEntries,
      );
    }
    final normalizedBarcode = barcode.trim();
    for (final entry in liveEntries) {
      if (entry.barcode == normalizedBarcode) {
        return CachedScanLookup(
          identity: entry.product,
          cachedAt: entry.cachedAt,
        );
      }
    }
    return null;
  }

  Future<void> clearForUser(String userId) async {
    final prefix = '$_keyPrefix${Uri.encodeComponent(userId)}.';
    final matchingKeys = await storage.keys(prefix: prefix);
    await Future.wait(matchingKeys.map(storage.delete));
  }

  bool _isExpired(_LookupEntry entry, DateTime now) {
    return !entry.cachedAt.add(ttl).isAfter(now);
  }

  Future<_LookupEnvelope?> _readEnvelope({
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
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Lookup cache must be a JSON object.');
      }
      final envelope = _LookupEnvelope.fromJson(decoded);
      if (envelope.schema != schemaVersion ||
          envelope.userId != userId ||
          envelope.warehouseId != warehouseId) {
        throw const FormatException(
          'Lookup cache ownership or schema mismatch.',
        );
      }
      return envelope;
    } on Object {
      await storage.delete(key);
      return null;
    }
  }

  Future<void> _writeEnvelope({
    required String userId,
    required int warehouseId,
    required List<_LookupEntry> entries,
  }) {
    final value = jsonEncode(<String, Object?>{
      'schemaVersion': schemaVersion,
      'userId': userId,
      'warehouseId': warehouseId,
      'entries': entries.map((entry) => entry.toJson()).toList(),
    });
    return storage.write(
      storageKey(userId: userId, warehouseId: warehouseId),
      value,
    );
  }
}

final class _LookupEnvelope {
  const _LookupEnvelope({
    required this.schema,
    required this.userId,
    required this.warehouseId,
    required this.entries,
  });

  factory _LookupEnvelope.fromJson(Map<String, Object?> json) {
    final rawEntries = json['entries'];
    if (rawEntries is! List<Object?>) {
      throw const FormatException('Lookup entries must be a list.');
    }
    return _LookupEnvelope(
      schema: _requiredInt(json, 'schemaVersion'),
      userId: _requiredString(json, 'userId'),
      warehouseId: _requiredInt(json, 'warehouseId'),
      entries: rawEntries.map((entry) {
        if (entry is! Map<String, Object?>) {
          throw const FormatException('Lookup entry must be an object.');
        }
        return _LookupEntry.fromJson(entry);
      }).toList(),
    );
  }

  final int schema;
  final String userId;
  final int warehouseId;
  final List<_LookupEntry> entries;
}

final class _LookupEntry {
  const _LookupEntry({
    required this.barcode,
    required this.product,
    required this.cachedAt,
  });

  factory _LookupEntry.fromJson(Map<String, Object?> json) {
    final rawProduct = json['product'];
    if (rawProduct is! Map<String, Object?>) {
      throw const FormatException('Cached product must be an object.');
    }
    return _LookupEntry(
      barcode: _requiredString(json, 'barcode'),
      product: ScanProductIdentity.fromJson(rawProduct),
      cachedAt: DateTime.parse(_requiredString(json, 'cachedAt')).toUtc(),
    );
  }

  final String barcode;
  final ScanProductIdentity product;
  final DateTime cachedAt;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'barcode': barcode,
      'product': product.toJson(),
      'cachedAt': cachedAt.toIso8601String(),
    };
  }
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) {
    return value;
  }
  throw FormatException('$key must be an integer.');
}

int? _optionalInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is int) {
    return value as int?;
  }
  throw FormatException('$key must be an integer or null.');
}

double? _optionalDouble(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toDouble();
  }
  throw FormatException('$key must be numeric or null.');
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) {
    return value;
  }
  throw FormatException('$key must be a string.');
}
