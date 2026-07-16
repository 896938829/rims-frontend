import 'dart:convert';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rims_frontend/features/documents/presentation/view_models/documents_view_model.dart';
import 'package:rims_frontend/core/config/app_environment.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/features/inventory/presentation/widgets/inventory_product_tile.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/main.dart';

import 'support/rims_e2e_driver.dart';
import 'support/rims_e2e_config.dart';

late final IntegrationTestWidgetsFlutterBinding binding;

void main() {
  binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('local acceptance journey', (tester) async {
    await screenshotOnFailure(
      binding,
      'local-acceptance-journey-failure',
      () async {
        final runId = DateTime.now().microsecondsSinceEpoch.toString();
        final startedAt = DateTime.now();
        var segmentStartedAt = startedAt;
        final segmentDurations = <String, int>{};
        void recordSegment(String name) {
          final now = DateTime.now();
          segmentDurations[name] = now
              .difference(segmentStartedAt)
              .inMilliseconds;
          segmentStartedAt = now;
        }

        await _pumpFreshApp(tester, 'initial');
        debugPrint('E2E stage: initial app');
        await _normalizeLoggedOutState(tester);
        debugPrint('E2E stage: normalized logout');
        await tester.pump(const Duration(seconds: 2));
        await _login(
          tester,
          username: RimsE2eConfig.adminUsername,
          password: RimsE2eConfig.adminPassword,
        );

        await waitForKey(tester, const Key('bottom-nav-home'));
        debugPrint('E2E stage: admin login');
        await _selectAdminWarehouse(tester, '默认仓库');
        await tapAndSettle(tester, const Key('bottom-nav-home'));
        await expectText(tester, '默认仓库');

        await _pumpFreshApp(tester, 'session-restore');
        await waitUntil(
          tester,
          description: 'restored shell without login form',
          condition: () =>
              find.byKey(const Key('bottom-nav-home')).evaluate().isNotEmpty &&
              find.byKey(const Key('login-username-field')).evaluate().isEmpty,
        );
        expect(find.byKey(const Key('login-username-field')), findsNothing);
        debugPrint('E2E stage: session restored');

        await tapAndSettle(tester, const Key('bottom-nav-inventory'));
        final firstWarehouse = await _loadFixtureInventory(tester);
        debugPrint('E2E stage: first inventory ${firstWarehouse.quantity}');
        expect(firstWarehouse.quantity, 2);

        await _selectAdminWarehouse(tester, RimsE2eConfig.secondWarehouseName);
        debugPrint('E2E stage: warehouse switched');

        await tapAndSettle(tester, const Key('bottom-nav-inventory'));
        final secondWarehouse = await _loadFixtureInventory(tester);
        debugPrint('E2E stage: second inventory ${secondWarehouse.quantity}');
        expect(secondWarehouse.quantity, 12);
        recordSegment('adminSession');

        final inboundNumber = await _createAndCompleteDocument(
          tester,
          actionKey: const Key('document-action-inbound'),
          productId: secondWarehouse.productId,
          quantity: 3,
          remark: 'M9-E2E:$runId:inbound',
        );
        final afterInbound = await _searchFixtureInventory(tester);
        expect(afterInbound.quantity, secondWarehouse.quantity + 3);

        final salesNumber = await _createAndCompleteDocument(
          tester,
          actionKey: const Key('document-action-sales'),
          productId: secondWarehouse.productId,
          quantity: 2,
          remark: 'M9-E2E:$runId:sales',
        );
        final afterSales = await _searchFixtureInventory(tester);
        expect(afterSales.quantity, secondWarehouse.quantity + 1);
        recordSegment('stockImpact');

        await _logout(tester);
        await _login(
          tester,
          username: RimsE2eConfig.operatorUsername,
          password: RimsE2eConfig.operatorPassword,
        );
        await waitUntil(
          tester,
          description: 'operator shell',
          condition: () =>
              find.byKey(const Key('bottom-nav-home')).evaluate().isNotEmpty &&
              find.byKey(const Key('login-username-field')).evaluate().isEmpty,
        );
        await _assertOperatorProfileBoundary(tester);
        final operatorInventory = await _searchFixtureInventory(tester);
        expect(operatorInventory.productId, greaterThan(0));
        await _assertHandledInboundDenial(
          tester,
          productId: operatorInventory.productId,
          remark: 'M9-E2E:$runId:operator-denied',
        );
        await _assertOperatorReports(tester);
        recordSegment('operatorBoundary');

        await _logout(tester);
        await _pumpFreshApp(tester, 'logged-out-restart');
        await waitUntil(
          tester,
          description: 'login form after logged-out restart',
          condition: () {
            final login = find.byKey(const Key('login-username-field'));
            return login.evaluate().isNotEmpty &&
                tester.widget<TextField>(login).enabled == true &&
                find.byKey(const Key('bottom-nav-home')).evaluate().isEmpty;
          },
        );
        recordSegment('logout');
        final reportData = <String, Object?>{
          'phase': 'baseline',
          'runId': runId,
          'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
          'segmentsMs': segmentDurations,
          'documents': <String>[inboundNumber, salesNumber],
        };
        binding.reportData = reportData;
        debugPrint('RIMS_E2E_RESULT ${jsonEncode(reportData)}');
        await tester.pump(const Duration(seconds: 1));
        await settleBounded(tester);
      },
    );
  });
}

Future<void> _selectAdminWarehouse(
  WidgetTester tester,
  String warehouseName,
) async {
  await tapAndSettle(tester, const Key('bottom-nav-profile'));
  await tapAndSettle(tester, const Key('profile-warehouse-selector'));
  await tapFinderAndSettle(
    tester,
    find.text(warehouseName).last,
    description: '$warehouseName warehouse option',
  );
  await expectText(tester, warehouseName);
}

Future<void> _logout(WidgetTester tester) async {
  await tapAndSettle(tester, const Key('bottom-nav-profile'));
  await scrollUntilVisible(tester, const Key('profile-logout-button'));
  await tapAndSettle(tester, const Key('profile-logout-button'));
  await tapAndSettle(tester, const Key('profile-logout-retain-drafts'));
  await waitForKey(tester, const Key('login-username-field'));
}

Future<void> _assertOperatorProfileBoundary(WidgetTester tester) async {
  await tapAndSettle(tester, const Key('bottom-nav-profile'));
  await waitForKey(tester, const Key('profile-assigned-warehouses'));
  final assignedWarehouses = find.descendant(
    of: find.byKey(const Key('profile-assigned-warehouses')),
    matching: find.byType(Text),
  );
  final warehouseSummary = tester
      .widgetList<Text>(assignedWarehouses)
      .map((text) => text.data ?? '')
      .join(' ');
  expect(warehouseSummary, contains('默认仓库'));
  expect(warehouseSummary, contains(RimsE2eConfig.secondWarehouseName));
  expect(find.byKey(const Key('profile-warehouse-selector')), findsNothing);

  final forbiddenKeys = <Key>{
    const Key('profile-admin-users'),
    const Key('profile-admin-products'),
    const Key('profile-admin-warehouses'),
  };
  final seenForbiddenKeys = <Key>{};
  final seenTexts = <String>{};
  final scroll = find
      .descendant(
        of: find.byKey(const Key('tab-body-profile')),
        matching: find.byType(Scrollable),
      )
      .hitTestable();
  for (var step = 0; step < 30; step += 1) {
    for (final key in forbiddenKeys) {
      if (find.byKey(key).evaluate().isNotEmpty) seenForbiddenKeys.add(key);
    }
    seenTexts.addAll(
      tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .whereType<String>(),
    );
    final state = tester.state<ScrollableState>(scroll.first);
    if (state.position.pixels >= state.position.maxScrollExtent) break;
    await tester.drag(scroll.first, const Offset(0, -360));
    await tester.pump(const Duration(milliseconds: 100));
  }
  final profilePosition = tester.state<ScrollableState>(scroll.first).position;
  expect(
    profilePosition.pixels,
    greaterThanOrEqualTo(profilePosition.maxScrollExtent - 1),
  );
  expect(seenForbiddenKeys, isEmpty);
  expect(seenTexts, isNot(contains('角色与权限')));
}

Future<void> _assertHandledInboundDenial(
  WidgetTester tester, {
  required int productId,
  required String remark,
}) async {
  await tapAndSettle(tester, const Key('bottom-nav-documents'));
  final documentsScroll = find.byKey(const Key('documents-scroll-view'));
  final viewModel = await _documentsViewModel(tester);
  await waitUntil(
    tester,
    description: 'operator documents page',
    condition: () =>
        !viewModel.isLoading && viewModel.recentDocuments.isNotEmpty,
  );
  final existingIds = viewModel.recentDocuments
      .map((document) => document.id)
      .toSet();
  await scrollUntilVisible(
    tester,
    const Key('document-action-inbound'),
    scrollable: documentsScroll,
  );
  await tapAndSettle(tester, const Key('document-action-inbound'));
  await enterText(
    tester,
    const Key('document-product-field'),
    RimsE2eConfig.fixtureProductCode,
  );
  await tapAndSettle(tester, Key('document-product-option-$productId'));
  await enterText(tester, const Key('document-quantity-field'), '1');
  await enterText(tester, const Key('document-remark-field'), remark);
  await scrollUntilVisible(
    tester,
    const Key('document-create-button'),
    scrollable: documentsScroll,
  );
  await tapAndSettle(tester, const Key('document-create-button'));
  await waitUntil(
    tester,
    description: 'handled ordinary-user inbound denial',
    condition: () => viewModel.formError != null,
  );
  expect(viewModel.formError, isNotEmpty);
  expect(
    viewModel.recentDocuments.map((document) => document.id).toSet(),
    existingIds,
  );
  expect(find.byKey(const Key('tab-body-documents')), findsOneWidget);
}

Future<void> _assertOperatorReports(WidgetTester tester) async {
  await tapAndSettle(tester, const Key('bottom-nav-reports'));
  await waitForKey(tester, const Key('tab-body-reports'));
  await expectText(tester, '库存概览');
  final texts = <String>{};
  final scroll = find
      .descendant(
        of: find.byKey(const Key('tab-body-reports')),
        matching: find.byType(Scrollable),
      )
      .hitTestable();
  for (var step = 0; step < 30; step += 1) {
    texts.addAll(
      tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .whereType<String>(),
    );
    final state = tester.state<ScrollableState>(scroll.first);
    if (state.position.pixels >= state.position.maxScrollExtent) break;
    await tester.drag(scroll.first, const Offset(0, -360));
    await tester.pump(const Duration(milliseconds: 100));
  }
  final reportPosition = tester.state<ScrollableState>(scroll.first).position;
  expect(
    reportPosition.pixels,
    greaterThanOrEqualTo(reportPosition.maxScrollExtent - 1),
  );
  expect(texts, contains('库存概览'));
  expect(texts, isNot(contains('销售统计')));
  expect(texts, isNot(contains('销售趋势（元）')));
  expect(texts, isNot(contains('商品排行（销售额）')));
}

Future<void> _pumpFreshApp(WidgetTester tester, String instance) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pumpWidget(
    MainApp(
      key: ValueKey<String>(instance),
      offlineStore: MemoryOfflineStore(),
      secureStorage: AppSecureStorage(),
      configuration: AppConfiguration.fromCompileTimeDefines(
        isReleaseMode: kReleaseMode,
      ),
    ),
  );
  await tester.pump();
}

Future<void> _normalizeLoggedOutState(WidgetTester tester) async {
  DateTime? enabledLoginSince;
  await waitUntil(
    tester,
    description: 'enabled login form or restored shell',
    condition: () {
      if (find.byKey(const Key('bottom-nav-home')).evaluate().isNotEmpty) {
        return true;
      }
      final username = find.byKey(const Key('login-username-field'));
      final loginEnabled =
          username.evaluate().isNotEmpty &&
          tester.widget<TextField>(username).enabled == true;
      if (!loginEnabled) {
        enabledLoginSince = null;
        return false;
      }
      enabledLoginSince ??= DateTime.now();
      return DateTime.now().difference(enabledLoginSince!) >=
          const Duration(seconds: 1);
    },
  );
  if (find.byKey(const Key('bottom-nav-home')).evaluate().isEmpty) return;

  await tapAndSettle(tester, const Key('bottom-nav-profile'));
  await tester.pump(const Duration(seconds: 2));
  await settleBounded(tester);
  await scrollUntilVisible(tester, const Key('profile-logout-button'));
  await tapAndSettle(tester, const Key('profile-logout-button'));
  await tapAndSettle(tester, const Key('profile-logout-retain-drafts'));
  await waitForKey(tester, const Key('login-username-field'));
}

Future<void> _login(
  WidgetTester tester, {
  required String username,
  required String password,
}) async {
  await enterText(tester, const Key('login-username-field'), username);
  await enterText(tester, const Key('login-password-field'), password);
  await tapFinderAndSettle(
    tester,
    find.widgetWithText(FilledButton, '登录'),
    description: 'login button',
  );
}

Future<_FixtureInventory> _loadFixtureInventory(WidgetTester tester) async {
  await waitForKey(tester, const Key('tab-body-inventory'));
  final fixtureProducts = <String>{};
  int? fixtureQuantity;
  int? fixtureProductId;
  final inventoryScroll = find
      .descendant(
        of: find.byKey(const Key('tab-body-inventory')),
        matching: find.byType(Scrollable),
      )
      .hitTestable();

  for (var step = 0; step < 120; step += 1) {
    await waitUntil(
      tester,
      description: 'inventory page data',
      condition: () =>
          find.byType(InventoryProductTile).evaluate().isNotEmpty ||
          find.byKey(const Key('inventory-page-end')).evaluate().isNotEmpty,
    );
    final tiles = tester
        .widgetList<InventoryProductTile>(find.byType(InventoryProductTile))
        .toList(growable: false);
    for (final tile in tiles) {
      if (tile.product.sku.startsWith('M9-PAGE-')) {
        fixtureProducts.add(tile.product.sku);
      }
      if (tile.product.sku == RimsE2eConfig.fixtureProductCode) {
        fixtureQuantity = tile.product.availableQuantity;
        fixtureProductId = tile.product.productId;
      }
    }

    final loadMoreKey = const Key('inventory-load-more-button');
    if (find.byKey(loadMoreKey).hitTestable().evaluate().isNotEmpty) {
      await tapAndSettle(tester, loadMoreKey);
      await tester.pump(const Duration(milliseconds: 500));
      continue;
    }
    if (fixtureQuantity != null && fixtureProducts.length > 20) {
      return _FixtureInventory(
        productId: fixtureProductId!,
        quantity: fixtureQuantity,
      );
    }
    if (find.byKey(const Key('inventory-page-end')).evaluate().isNotEmpty) {
      break;
    }
    if (inventoryScroll.evaluate().isEmpty) {
      throw TestFailure('Inventory scrollable is not hit-testable');
    }
    await tester.drag(inventoryScroll.first, const Offset(0, -420));
    await tester.pump(const Duration(milliseconds: 100));
  }

  throw TestFailure(
    'Expected ${RimsE2eConfig.fixtureProductCode} and more than 20 distinct '
    'M9 fixture rows, rendered ${fixtureProducts.length}: '
    '${fixtureProducts.toList()..sort()}',
  );
}

Future<_FixtureInventory> _searchFixtureInventory(WidgetTester tester) async {
  await tapAndSettle(tester, const Key('bottom-nav-inventory'));
  await scrollUntilVisible(tester, const Key('inventory-search-field'));
  await enterText(
    tester,
    const Key('inventory-search-field'),
    RimsE2eConfig.fixtureProductCode,
  );
  await waitUntil(
    tester,
    description: 'searched fixture inventory',
    condition: () => tester
        .widgetList<InventoryProductTile>(find.byType(InventoryProductTile))
        .any((tile) => tile.product.sku == RimsE2eConfig.fixtureProductCode),
  );
  final tile = tester
      .widgetList<InventoryProductTile>(find.byType(InventoryProductTile))
      .singleWhere(
        (tile) => tile.product.sku == RimsE2eConfig.fixtureProductCode,
      );
  return _FixtureInventory(
    productId: tile.product.productId,
    quantity: tile.product.availableQuantity,
  );
}

Future<String> _createAndCompleteDocument(
  WidgetTester tester, {
  required Key actionKey,
  required int productId,
  required int quantity,
  required String remark,
}) async {
  await tapAndSettle(tester, const Key('bottom-nav-documents'));
  await waitForKey(tester, const Key('tab-body-documents'));
  final documentsScroll = find.byKey(const Key('documents-scroll-view'));
  final viewModel = await _documentsViewModel(tester);
  await waitUntil(
    tester,
    description: 'initial documents page',
    condition: () =>
        !viewModel.isLoading && viewModel.recentDocuments.isNotEmpty,
  );
  final existingIds = viewModel.recentDocuments
      .map((document) => document.id)
      .toSet();

  await scrollUntilVisible(tester, actionKey, scrollable: documentsScroll);
  await tapAndSettle(tester, actionKey);
  await scrollUntilVisible(
    tester,
    const Key('document-product-field'),
    scrollable: documentsScroll,
  );
  await enterText(
    tester,
    const Key('document-product-field'),
    RimsE2eConfig.fixtureProductCode,
  );
  final optionKey = Key('document-product-option-$productId');
  await waitForKey(tester, optionKey);
  await tapAndSettle(tester, optionKey);
  await enterText(
    tester,
    const Key('document-quantity-field'),
    quantity.toString(),
  );
  await enterText(tester, const Key('document-remark-field'), remark);
  await scrollUntilVisible(
    tester,
    const Key('document-create-button'),
    scrollable: documentsScroll,
  );
  await tapAndSettle(tester, const Key('document-create-button'));

  await waitUntil(
    tester,
    description: 'created document $remark',
    condition: () => viewModel.recentDocuments.any(
      (document) =>
          !existingIds.contains(document.id) && document.remark == remark,
    ),
  );
  final created = viewModel.recentDocuments.firstWhere(
    (document) =>
        !existingIds.contains(document.id) && document.remark == remark,
  );
  final completeKey = Key('document-complete-${created.id}');
  await scrollUntilVisible(tester, completeKey, scrollable: documentsScroll);
  await tapAndSettle(tester, completeKey);
  await tapFinderAndSettle(
    tester,
    find.widgetWithText(FilledButton, '确认完成'),
    description: 'confirm completing ${created.number}',
  );
  await waitUntil(
    tester,
    description: 'completed document ${created.number} and transaction',
    condition: () {
      final completed = viewModel.recentDocuments.any(
        (document) => document.id == created.id && document.status == '已完成',
      );
      final transaction = viewModel.transactions.any(
        (item) => item.docId == created.id && item.docNo == created.number,
      );
      return completed && transaction;
    },
  );
  return created.number;
}

Future<DocumentsViewModel> _documentsViewModel(WidgetTester tester) async {
  final finder = find.byWidgetPredicate(
    (widget) =>
        widget is AnimatedBuilder && widget.animation is DocumentsViewModel,
  );
  await waitUntil(
    tester,
    description: 'documents view model',
    condition: () => finder.evaluate().isNotEmpty,
  );
  return tester.widget<AnimatedBuilder>(finder.first).animation
      as DocumentsViewModel;
}

final class _FixtureInventory {
  const _FixtureInventory({required this.productId, required this.quantity});

  final int productId;
  final int quantity;
}
