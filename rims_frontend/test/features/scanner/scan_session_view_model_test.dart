import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/inventory/domain/entities/inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/entities/non_standard_inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/repositories/inventory_repository.dart';
import 'package:rims_frontend/features/scanner/domain/entities/scan_data.dart';
import 'package:rims_frontend/features/scanner/domain/services/scan_feedback_capability.dart';
import 'package:rims_frontend/features/scanner/domain/services/scan_lookup_cache.dart';
import 'package:rims_frontend/features/scanner/domain/services/scan_session_store.dart';
import 'package:rims_frontend/features/scanner/presentation/view_models/scan_session_view_model.dart';

void main() {
  group('scan modes', () {
    test('single accepts the first product and ignores later scans', () async {
      final repository = _FakeInventoryRepository(
        onFind: (barcode) async => Success(_item(barcode == 'A' ? 1 : 2)),
      );
      final harness = _Harness(repository: repository, mode: ScanMode.single);

      await harness.viewModel.accept(_scan('A'));
      await harness.viewModel.accept(_scan('B'));

      expect(harness.viewModel.lines.single.item.productId, 1);
      expect(harness.viewModel.isComplete, isTrue);
      expect(repository.lookups, ['A']);
    });

    test(
      'continuous accepts distinct products and rejects within cooldown',
      () async {
        var now = DateTime.utc(2026, 7, 13, 8);
        final harness = _Harness(
          repository: _FakeInventoryRepository(
            onFind: (barcode) async => Success(_item(barcode == 'A' ? 1 : 2)),
          ),
          mode: ScanMode.continuous,
          now: () => now,
        );

        await harness.viewModel.accept(_scan('A'));
        now = now.add(const Duration(milliseconds: 500));
        await harness.viewModel.accept(_scan('A'));
        await harness.viewModel.accept(_scan('B'));

        expect(harness.viewModel.lines.map((line) => line.item.productId), [
          1,
          2,
        ]);
        expect(harness.feedback.kinds, [
          ScanFeedbackKind.accepted,
          ScanFeedbackKind.duplicate,
          ScanFeedbackKind.accepted,
        ]);
      },
    );

    test('continuous accepts the same product again after cooldown', () async {
      var now = DateTime.utc(2026, 7, 13, 8);
      final harness = _Harness(
        repository: _FakeInventoryRepository(
          onFind: (_) async => Success(_item(1)),
        ),
        mode: ScanMode.continuous,
        now: () => now,
      );
      await harness.viewModel.accept(_scan('A'));

      now = now.add(const Duration(seconds: 2));
      await harness.viewModel.accept(_scan('A'));

      expect(harness.viewModel.lines, hasLength(1));
      expect(harness.feedback.kinds, [
        ScanFeedbackKind.accepted,
        ScanFeedbackKind.accepted,
      ]);
    });

    test('batch keeps one line per product', () async {
      final harness = _Harness(
        repository: _FakeInventoryRepository(
          onFind: (_) async => Success(_item(1)),
        ),
        mode: ScanMode.batch,
      );

      await harness.viewModel.accept(_scan('A'));
      await harness.viewModel.accept(_scan('A'));

      expect(harness.viewModel.lines, hasLength(1));
      expect(harness.viewModel.lines.single.quantity, 1);
      expect(harness.feedback.kinds.last, ScanFeedbackKind.duplicate);
    });

    test('quantity accumulates repeated scans into one line', () async {
      final harness = _Harness(
        repository: _FakeInventoryRepository(
          onFind: (_) async => Success(_item(1)),
        ),
        mode: ScanMode.quantity,
      );

      await harness.viewModel.accept(_scan('A'));
      await harness.viewModel.accept(_scan('A'));
      await harness.viewModel.accept(_scan('A'));

      expect(harness.viewModel.lines, hasLength(1));
      expect(harness.viewModel.lines.single.quantity, 3);
      expect(harness.feedback.kinds, everyElement(ScanFeedbackKind.accepted));
    });
  });

  test('increment and decrement update quantity and remove at zero', () async {
    final harness = _Harness(
      repository: _FakeInventoryRepository(
        onFind: (_) async => Success(_item(1)),
      ),
      mode: ScanMode.quantity,
    );
    await harness.viewModel.accept(_scan('A'));

    await harness.viewModel.increment(1);
    expect(harness.viewModel.lines.single.quantity, 2);
    await harness.viewModel.decrement(1);
    expect(harness.viewModel.lines.single.quantity, 1);
    await harness.viewModel.decrement(1);
    expect(harness.viewModel.lines, isEmpty);
  });

  test(
    'maxLines rejects a new product without changing existing lines',
    () async {
      final harness = _Harness(
        repository: _FakeInventoryRepository(
          onFind: (barcode) async => Success(_item(barcode == 'A' ? 1 : 2)),
        ),
        mode: ScanMode.batch,
        maxLines: 1,
      );

      await harness.viewModel.accept(_scan('A'));
      await harness.viewModel.accept(_scan('B'));

      expect(harness.viewModel.lines.single.item.productId, 1);
      expect(harness.viewModel.issue, ScanIssue.maxLines);
      expect(harness.feedback.kinds.last, ScanFeedbackKind.rejected);
    },
  );

  group('input and failure classification', () {
    test(
      'empty and unsupported values reject without repository lookup',
      () async {
        final repository = _FakeInventoryRepository(
          onFind: (_) async => Success(_item(1)),
        );
        final harness = _Harness(repository: repository);

        await harness.viewModel.accept(_scan('   '));
        expect(harness.viewModel.issue, ScanIssue.empty);
        await harness.viewModel.accept(
          _scan('A', format: ScanCodeFormat.unknown),
        );

        expect(harness.viewModel.issue, ScanIssue.unsupported);
        expect(repository.lookups, isEmpty);
        expect(harness.feedback.kinds, [
          ScanFeedbackKind.rejected,
          ScanFeedbackKind.rejected,
        ]);
      },
    );

    final cases = <(String, Failure, ScanIssue)>[
      (
        'unknown',
        const NotFoundFailure(message: 'not found'),
        ScanIssue.unknown,
      ),
      (
        'disabled',
        const InventoryFailure(message: 'product disabled'),
        ScanIssue.disabled,
      ),
      (
        'wrong warehouse',
        const InventoryFailure(message: '当前仓库库存已停用'),
        ScanIssue.wrongWarehouse,
      ),
      (
        'wrong batch',
        const InventoryFailure(message: 'wrong batch'),
        ScanIssue.wrongBatch,
      ),
      (
        'permission',
        const AuthorizationFailure(message: 'denied'),
        ScanIssue.permissionDenied,
      ),
      (
        'network without cache',
        const NetworkFailure(message: 'offline'),
        ScanIssue.network,
      ),
    ];

    for (final (name, failure, expected) in cases) {
      test('maps $name failure to $expected', () async {
        final harness = _Harness(
          repository: _FakeInventoryRepository(
            onFind: (_) async => FailureResult<InventoryItem>(failure),
          ),
        );

        await harness.viewModel.accept(_scan('A'));

        expect(harness.viewModel.issue, expected);
        expect(harness.viewModel.message, failure.message);
        expect(harness.feedback.kinds.single, ScanFeedbackKind.rejected);
      });
    }
  });

  test('feedback forwards kind and configured sound/vibration flags', () async {
    final harness = _Harness(
      repository: _FakeInventoryRepository(
        onFind: (_) async => Success(_item(1)),
      ),
      soundEnabled: false,
      vibrationEnabled: true,
    );

    await harness.viewModel.accept(_scan('A'));

    expect(
      harness.feedback.calls.single,
      const _FeedbackCall(ScanFeedbackKind.accepted, false, true),
    );
  });

  test('suppresses an older asynchronous lookup result', () async {
    final first = Completer<Result<InventoryItem>>();
    final second = Completer<Result<InventoryItem>>();
    final repository = _FakeInventoryRepository(
      onFind: (barcode) => barcode == 'A' ? first.future : second.future,
    );
    final harness = _Harness(repository: repository, mode: ScanMode.batch);

    final firstAccept = harness.viewModel.accept(_scan('A'));
    final secondAccept = harness.viewModel.accept(_scan('B'));
    second.complete(Success(_item(2)));
    await secondAccept;
    first.complete(Success(_item(1)));
    await firstAccept;

    expect(harness.viewModel.lines.map((line) => line.item.productId), [2]);
    expect(harness.feedback.kinds, [ScanFeedbackKind.accepted]);
    expect(harness.viewModel.isLookingUp, isFalse);
  });

  group('submit', () {
    test('success clears lines and plays completed feedback', () async {
      final harness = _Harness(
        repository: _FakeInventoryRepository(
          onFind: (_) async => Success(_item(1)),
        ),
        mode: ScanMode.batch,
      );
      await harness.viewModel.accept(_scan('A'));
      late List<ScanLine> submitted;

      final result = await harness.viewModel.submit((lines) async {
        submitted = lines;
        return const Success<void>(null);
      });

      expect(result.isSuccess, isTrue);
      expect(submitted.single.item.productId, 1);
      expect(harness.viewModel.lines, isEmpty);
      expect(harness.feedback.kinds.last, ScanFeedbackKind.completed);
      expect(
        await harness.store.restore(userId: 'user-1', warehouseId: 7),
        isNull,
      );
    });

    test('failure retains lines and exposes its message', () async {
      final harness = _Harness(
        repository: _FakeInventoryRepository(
          onFind: (_) async => Success(_item(1)),
        ),
        mode: ScanMode.batch,
      );
      await harness.viewModel.accept(_scan('A'));

      final result = await harness.viewModel.submit(
        (_) async => const FailureResult<void>(
          NetworkFailure(message: 'submit offline'),
        ),
      );

      expect(result.isFailure, isTrue);
      expect(harness.viewModel.lines, hasLength(1));
      expect(harness.viewModel.message, 'submit offline');
      expect(harness.feedback.kinds, [ScanFeedbackKind.accepted]);
    });
  });

  test('network failure falls back to cached identity as stale', () async {
    final storage = _MemoryScanStorage();
    final cache = ScanLookupCache(storage: storage);
    await cache.put(
      userId: 'user-1',
      warehouseId: 7,
      barcode: 'A',
      item: _item(9, availableQuantity: 30, stockQuantity: 40),
    );
    final harness = _Harness(
      repository: _FakeInventoryRepository(
        onFind: (_) async => const FailureResult<InventoryItem>(
          NetworkFailure(message: 'offline'),
        ),
      ),
      mode: ScanMode.batch,
      storage: storage,
    );

    await harness.viewModel.accept(_scan('A'));

    final line = harness.viewModel.lines.single;
    expect(line.item.productId, 9);
    expect(line.isStale, isTrue);
    expect(line.item.availableQuantity, 0);
    expect(line.item.stockQuantity, 0);
    expect(harness.viewModel.issue, isNull);
    expect(harness.feedback.kinds.single, ScanFeedbackKind.accepted);
  });

  test(
    'repository cache success remains stale and non-authoritative',
    () async {
      final harness = _Harness(
        repository: _FakeInventoryRepository(
          onFind: (_) async =>
              Success(_item(9, availableQuantity: 0, stockQuantity: 0)),
          readStatus: InventoryReadStatus(
            source: InventoryDataSource.cache,
            fetchedAt: DateTime.utc(2026, 7, 13),
            expiresAt: DateTime.utc(2026, 7, 14),
          ),
        ),
        mode: ScanMode.batch,
      );

      await harness.viewModel.accept(_scan('A'));

      expect(harness.viewModel.lines.single.isStale, isTrue);
      await expectLater(
        harness.cache.storage.keys(prefix: 'rims.scanner.lookup.'),
        completion(isEmpty),
      );
    },
  );
}

final class _Harness {
  _Harness({
    required _FakeInventoryRepository repository,
    ScanMode mode = ScanMode.single,
    int maxLines = 100,
    DateTime Function()? now,
    bool soundEnabled = true,
    bool vibrationEnabled = true,
    _MemoryScanStorage? storage,
  }) : storage = storage ?? _MemoryScanStorage(),
       feedback = _FakeFeedback() {
    cache = ScanLookupCache(storage: this.storage, now: now);
    store = ScanSessionStore(storage: this.storage);
    viewModel = ScanSessionViewModel(
      inventoryRepository: repository,
      userId: 'user-1',
      warehouseId: 7,
      feedback: feedback,
      cache: cache,
      store: store,
      mode: mode,
      maxLines: maxLines,
      duplicateCooldown: const Duration(seconds: 2),
      soundEnabled: soundEnabled,
      vibrationEnabled: vibrationEnabled,
      now: now,
    );
  }

  final _MemoryScanStorage storage;
  final _FakeFeedback feedback;
  late final ScanLookupCache cache;
  late final ScanSessionStore store;
  late final ScanSessionViewModel viewModel;
}

final class _FakeInventoryRepository
    implements InventoryRepository, InventoryReadMetadata {
  _FakeInventoryRepository({required this.onFind, this.readStatus});

  final Future<Result<InventoryItem>> Function(String barcode) onFind;
  final List<String> lookups = <String>[];
  final InventoryReadStatus? readStatus;

  @override
  InventoryReadStatus? get lastReadStatus => readStatus;

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) {
    lookups.add(barcode);
    return onFind(barcode);
  }

  @override
  Future<Result<PageData<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) => throw UnimplementedError();

  @override
  Future<Result<PageData<InventoryItem>>> listInventoryAlerts({int page = 1}) =>
      throw UnimplementedError();

  @override
  Future<Result<PageData<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  }) => throw UnimplementedError();

  @override
  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) => throw UnimplementedError();
}

final class _FakeFeedback implements ScanFeedbackCapability {
  final List<_FeedbackCall> calls = <_FeedbackCall>[];

  List<ScanFeedbackKind> get kinds => calls.map((call) => call.kind).toList();

  @override
  Future<void> play(
    ScanFeedbackKind kind, {
    required bool sound,
    required bool vibration,
  }) async {
    calls.add(_FeedbackCall(kind, sound, vibration));
  }
}

final class _FeedbackCall {
  const _FeedbackCall(this.kind, this.sound, this.vibration);

  final ScanFeedbackKind kind;
  final bool sound;
  final bool vibration;

  @override
  bool operator ==(Object other) {
    return other is _FeedbackCall &&
        other.kind == kind &&
        other.sound == sound &&
        other.vibration == vibration;
  }

  @override
  int get hashCode => Object.hash(kind, sound, vibration);
}

final class _MemoryScanStorage implements AsyncScanStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<Set<String>> keys({required String prefix}) async {
    return values.keys.where((key) => key.startsWith(prefix)).toSet();
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

ScanData _scan(String value, {ScanCodeFormat format = ScanCodeFormat.code128}) {
  return ScanData(
    value: value,
    format: format,
    capturedAt: DateTime.utc(2026, 7, 13),
  );
}

InventoryItem _item(
  int productId, {
  int availableQuantity = 5,
  int stockQuantity = 6,
}) {
  return InventoryItem(
    id: productId + 100,
    productId: productId,
    productName: 'Product $productId',
    sku: 'SKU-$productId',
    availableQuantity: availableQuantity,
    stockQuantity: stockQuantity,
    statusLabel: 'Enabled',
    imageUrl: '/products/$productId.png',
    status: 1,
  );
}
