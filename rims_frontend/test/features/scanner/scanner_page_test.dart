import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/inventory/domain/entities/inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/entities/non_standard_inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/repositories/inventory_repository.dart';
import 'package:rims_frontend/features/scanner/domain/entities/scan_data.dart';
import 'package:rims_frontend/features/scanner/domain/services/barcode_scanner_capability.dart';
import 'package:rims_frontend/features/scanner/domain/services/scan_lookup_cache.dart';
import 'package:rims_frontend/features/scanner/domain/services/scan_session_store.dart';
import 'package:rims_frontend/features/scanner/presentation/pages/scanner_page.dart';
import 'package:rims_frontend/features/scanner/presentation/view_models/scan_session_view_model.dart';
import 'package:rims_frontend/features/scanner/presentation/widgets/scanner_viewport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mode segmented control updates the scan session mode', (
    tester,
  ) async {
    final harness = _Harness();
    await _pumpScannerPage(tester, harness);
    await _scrollBelowViewport(tester);

    expect(find.byKey(const Key('scanner-mode-control')), findsOneWidget);
    for (final (label, mode) in <(String, ScanMode)>[
      ('连续', ScanMode.continuous),
      ('批量', ScanMode.batch),
      ('计数', ScanMode.quantity),
      ('单次', ScanMode.single),
    ]) {
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pump();
      expect(harness.viewModel.mode, mode);
    }
  });

  testWidgets('scanner viewport keeps a stable 4:3 aspect ratio', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 320,
            child: ScannerViewport(camera: ColoredBox(color: Colors.green)),
          ),
        ),
      ),
    );

    final size = tester.getSize(find.byKey(const Key('scanner-viewport')));
    expect(size.width, 320);
    expect(size.height, 240);
    expect(size.width / size.height, closeTo(4 / 3, 0.001));
  });

  testWidgets('torch zoom and viewport focus reach the scanner capability', (
    tester,
  ) async {
    final harness = _Harness();
    await _pumpScannerPage(tester, harness);

    final viewport = find.byKey(const Key('scanner-viewport'));
    final viewportTopLeft = tester.getTopLeft(viewport);
    final viewportSize = tester.getSize(viewport);
    await tester.tapAt(
      viewportTopLeft +
          Offset(viewportSize.width * 0.25, viewportSize.height * 0.75),
    );
    await tester.pump();

    final torch = find.byKey(const Key('scanner-torch-button'));
    await tester.scrollUntilVisible(torch, 300);
    await tester.tap(torch);
    await tester.pump();

    final slider = find.byKey(const Key('scanner-zoom-slider'));
    final sliderTopLeft = tester.getTopLeft(slider);
    final sliderSize = tester.getSize(slider);
    await tester.tapAt(
      sliderTopLeft + Offset(sliderSize.width * 0.75, sliderSize.height / 2),
    );
    await tester.pump();

    expect(harness.scanner.focusPoints.single.dx, closeTo(0.25, 0.01));
    expect(harness.scanner.focusPoints.single.dy, closeTo(0.75, 0.01));
    expect(harness.scanner.torchValues, [true]);
    expect(harness.scanner.zoomValues.single, inInclusiveRange(0.6, 0.9));
  });

  testWidgets('scan results and rejected formats show visible feedback', (
    tester,
  ) async {
    final harness = _Harness();
    await _pumpScannerPage(tester, harness);

    harness.scanner.emit(_scan('100'));
    await tester.pumpAndSettle();
    await _scrollBelowViewport(tester);
    expect(find.text('Product 100'), findsOneWidget);
    expect(find.text('SKU-100'), findsOneWidget);

    harness.scanner.emit(_scan('pdf', format: ScanCodeFormat.unknown));
    await tester.pumpAndSettle();
    expect(find.text('Unsupported barcode format'), findsOneWidget);
    expect(find.byKey(const Key('scanner-feedback-message')), findsOneWidget);
  });

  testWidgets('scan shows visible lookup feedback before backend completes', (
    tester,
  ) async {
    final lookup = Completer<Result<InventoryItem>>();
    final harness = _Harness(lookupResult: lookup);
    await _pumpScannerPage(tester, harness);

    harness.scanner.emit(_scan('100'));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('scanner-lookup-progress')), findsOneWidget);
    expect(find.text('正在查询条码...'), findsOneWidget);

    lookup.complete(Success(_item(100)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scanner-lookup-progress')), findsNothing);
  });

  testWidgets('batch mode renders one row for each accepted product', (
    tester,
  ) async {
    final harness = _Harness();
    await _pumpScannerPage(tester, harness);
    await _scrollBelowViewport(tester);
    await tester.tap(find.text('批量'));
    await tester.pump();

    harness.scanner.emit(_scan('101'));
    await tester.pumpAndSettle();
    harness.scanner.emit(_scan('102'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('scanner-line-101')), findsOneWidget);
    expect(find.byKey(const Key('scanner-line-102')), findsOneWidget);
    expect(find.text('Product 101'), findsOneWidget);
    expect(find.text('Product 102'), findsOneWidget);
  });

  testWidgets('manual input submits a trimmed barcode and renders its row', (
    tester,
  ) async {
    final harness = _Harness();
    await _pumpScannerPage(tester, harness);
    final input = find.byKey(const Key('scanner-manual-input'));
    await tester.scrollUntilVisible(input, 300);

    await tester.enterText(input, ' 103 ');
    await tester.tap(find.byKey(const Key('scanner-manual-submit')));
    await tester.pumpAndSettle();

    expect(harness.repository.lookups, ['103']);
    expect(find.text('Product 103'), findsOneWidget);
  });

  testWidgets('unsupported start shows the unsupported-device text', (
    tester,
  ) async {
    final harness = _Harness(startErrors: [UnsupportedError('no camera')]);
    await _pumpScannerPage(tester, harness);

    expect(find.text('此设备不支持相机扫码'), findsOneWidget);
    expect(find.byKey(const Key('scanner-permission-retry')), findsOneWidget);
    expect(find.byKey(const Key('scanner-open-settings')), findsNothing);
  });

  testWidgets('permission denial exposes settings and retry recovers', (
    tester,
  ) async {
    var settingsCalls = 0;
    final harness = _Harness(
      startErrors: [const DevicePermissionFailure(message: 'camera denied')],
    );
    harness.viewModel.setMode(ScanMode.batch);
    await _pumpScannerPage(
      tester,
      harness,
      onOpenSettings: () => settingsCalls += 1,
    );

    expect(find.text('需要相机权限才能扫描条码'), findsOneWidget);
    final manualInput = find.byKey(const Key('scanner-manual-input'));
    await tester.scrollUntilVisible(manualInput, 300);
    await tester.enterText(manualInput, ' 205 ');
    await tester.tap(find.byKey(const Key('scanner-manual-submit')));
    await tester.pumpAndSettle();
    expect(harness.repository.lookups, ['205']);
    expect(find.text('Product 205'), findsOneWidget);

    final settings = find.byKey(const Key('scanner-open-settings'));
    await tester.ensureVisible(settings);
    await tester.tap(settings);
    expect(settingsCalls, 1);

    final retry = find.byKey(const Key('scanner-permission-retry'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(harness.scanner.startCount, 2);
    expect(find.text('需要相机权限才能扫描条码'), findsNothing);
    expect(find.byKey(const Key('scanner-open-settings')), findsNothing);
  });

  testWidgets('inactive stops scanning and resume starts it again', (
    tester,
  ) async {
    final harness = _Harness();
    await _pumpScannerPage(tester, harness);
    expect(harness.scanner.startCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(harness.scanner.stopCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(harness.scanner.startCount, 2);
  });

  testWidgets('system back pops the scanner page and disposes capability', (
    tester,
  ) async {
    final harness = _Harness();
    await tester.pumpWidget(
      MaterialApp(
        initialRoute: '/scanner',
        routes: {
          '/': (_) => const Scaffold(body: Text('Previous page')),
          '/scanner': (_) => ScannerPage(
            viewModel: harness.viewModel,
            scanner: harness.scanner,
            camera: const ColoredBox(color: Colors.black),
          ),
        },
      ),
    );
    await tester.pump();

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();

    expect(find.text('Previous page'), findsOneWidget);
    expect(harness.scanner.disposeCount, 1);
    expect(harness.scanner.stopCount, greaterThanOrEqualTo(1));
  });

  testWidgets('single authoritative scan returns to the requesting page', (
    tester,
  ) async {
    final harness = _Harness();
    await tester.pumpWidget(
      MaterialApp(
        initialRoute: '/scanner',
        routes: {
          '/': (_) => const Scaffold(body: Text('Inventory page')),
          '/scanner': (_) => ScannerPage(
            viewModel: harness.viewModel,
            scanner: harness.scanner,
            camera: const ColoredBox(color: Colors.black),
            returnSingleResult: true,
          ),
        },
      ),
    );
    await tester.pump();

    harness.scanner.emit(_scan('301'));
    await tester.pumpAndSettle();

    expect(harness.repository.lookups, ['301']);
    expect(find.text('Inventory page'), findsOneWidget);
    expect(
      harness.storage.values.keys.where(
        (key) => key.startsWith('rims.scanner.session.v1.'),
      ),
      isEmpty,
    );
  });

  testWidgets('single manual fallback returns to the requesting page', (
    tester,
  ) async {
    final harness = _Harness();
    await tester.pumpWidget(
      MaterialApp(
        initialRoute: '/scanner',
        routes: {
          '/': (_) => const Scaffold(body: Text('Document page')),
          '/scanner': (_) => ScannerPage(
            viewModel: harness.viewModel,
            scanner: harness.scanner,
            camera: const ColoredBox(color: Colors.black),
            returnSingleResult: true,
          ),
        },
      ),
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('scanner-manual-input')),
      300,
    );
    await tester.enterText(
      find.byKey(const Key('scanner-manual-input')),
      ' 302 ',
    );
    await tester.tap(find.byKey(const Key('scanner-manual-submit')));
    await tester.pumpAndSettle();

    expect(harness.repository.lookups, ['302']);
    expect(find.text('Document page'), findsOneWidget);
    expect(
      harness.storage.values.keys.where(
        (key) => key.startsWith('rims.scanner.session.v1.'),
      ),
      isEmpty,
    );
  });

  testWidgets('narrow screen and large text render without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final harness = _Harness();

    await _pumpScannerPage(
      tester,
      harness,
      textScaler: const TextScaler.linear(2),
    );
    await tester.drag(
      find.byKey(const Key('scanner-page')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('scanner-mode-control')), findsOneWidget);
    expect(find.byKey(const Key('scanner-manual-input')), findsOneWidget);
  });
}

Future<void> _pumpScannerPage(
  WidgetTester tester,
  _Harness harness, {
  VoidCallback? onOpenSettings,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: ScannerPage(
        viewModel: harness.viewModel,
        scanner: harness.scanner,
        camera: const ColoredBox(key: Key('fake-camera'), color: Colors.black),
        onOpenSettings: onOpenSettings,
      ),
    ),
  );
  await tester.pump();
}

Future<void> _scrollBelowViewport(WidgetTester tester) async {
  await tester.drag(
    find.byKey(const Key('scanner-page')),
    const Offset(0, -350),
  );
  await tester.pumpAndSettle();
}

final class _Harness {
  _Harness({
    List<Object>? startErrors,
    Completer<Result<InventoryItem>>? lookupResult,
  }) : scanner = _FakeScanner(startErrors: startErrors),
       repository = _FakeInventoryRepository(lookupResult: lookupResult),
       storage = _MemoryScanStorage() {
    viewModel = ScanSessionViewModel(
      inventoryRepository: repository,
      userId: 'user-1',
      warehouseId: 7,
      cache: ScanLookupCache(storage: storage),
      store: ScanSessionStore(storage: storage),
      duplicateCooldown: Duration.zero,
      now: () => DateTime.utc(2026, 7, 13),
    );
  }

  final _FakeScanner scanner;
  final _FakeInventoryRepository repository;
  final _MemoryScanStorage storage;
  late final ScanSessionViewModel viewModel;
}

final class _FakeScanner implements BarcodeScannerCapability {
  _FakeScanner({List<Object>? startErrors})
    : startErrors = List<Object>.of(startErrors ?? const []);

  final StreamController<ScanData> _scans = StreamController.broadcast();
  final StreamController<ScannerAccessState> _accessStates =
      StreamController.broadcast();
  final List<Object> startErrors;
  final List<bool> torchValues = [];
  final List<double> zoomValues = [];
  final List<Offset> focusPoints = [];
  int startCount = 0;
  int stopCount = 0;
  int disposeCount = 0;

  @override
  ScannerAccessState accessState = ScannerAccessState.ready;

  @override
  Stream<ScannerAccessState> get accessStates => _accessStates.stream;

  @override
  Stream<ScanData> get scans => _scans.stream;

  @override
  Future<void> start() async {
    startCount += 1;
    if (startErrors.isNotEmpty) throw startErrors.removeAt(0);
    accessState = ScannerAccessState.ready;
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
  }

  @override
  Future<void> setTorch(bool enabled) async {
    torchValues.add(enabled);
  }

  @override
  Future<void> setZoom(double value) async {
    zoomValues.add(value);
  }

  @override
  Future<void> focus(double x, double y) async {
    focusPoints.add(Offset(x, y));
  }

  @override
  Future<void> dispose() async {
    disposeCount += 1;
    if (!_scans.isClosed) await _scans.close();
    if (!_accessStates.isClosed) await _accessStates.close();
  }

  void emit(ScanData scan) => _scans.add(scan);
}

final class _FakeInventoryRepository implements InventoryRepository {
  _FakeInventoryRepository({this.lookupResult});

  final Completer<Result<InventoryItem>>? lookupResult;
  final List<String> lookups = [];

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) async {
    lookups.add(barcode);
    if (lookupResult case final pending?) return pending.future;
    final id = int.tryParse(barcode) ?? 1;
    return Success(_item(id));
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

final class _MemoryScanStorage implements AsyncScanStorage {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<Set<String>> keys({required String prefix}) async =>
      values.keys.where((key) => key.startsWith(prefix)).toSet();

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

ScanData _scan(String value, {ScanCodeFormat format = ScanCodeFormat.code128}) {
  return ScanData(
    value: value,
    format: format,
    capturedAt: DateTime.utc(2026, 7, 13),
  );
}

InventoryItem _item(int id) {
  return InventoryItem(
    id: id + 1000,
    productId: id,
    productName: 'Product $id',
    sku: 'SKU-$id',
    availableQuantity: 10,
    stockQuantity: 12,
    statusLabel: 'Enabled',
    imageUrl: '',
    status: 1,
  );
}
