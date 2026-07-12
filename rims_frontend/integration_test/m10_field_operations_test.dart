import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rims_frontend/features/attachments/presentation/widgets/attachment_panel.dart';
import 'package:rims_frontend/features/documents/presentation/view_models/documents_view_model.dart';
import 'package:rims_frontend/main.dart';

import 'support/rims_e2e_config.dart';
import 'support/rims_e2e_driver.dart';

late final IntegrationTestWidgetsFlutterBinding binding;

void main() {
  binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('M10 Android field operations', (tester) async {
    expect(RimsE2eConfig.fieldOperationsEnabled, isTrue);
    expect(RimsE2eConfig.injectedBarcode, isNotEmpty);
    expect(RimsE2eConfig.injectedPickedFile, isNotEmpty);

    await screenshotOnFailure(
      binding,
      'm10-field-operations-failure',
      () async {
        final startedAt = DateTime.now();
        final segments = <String, int>{};
        final runId = DateTime.now().microsecondsSinceEpoch.toString();

        segments['realCameraProbe'] = 0;

        await _pumpFreshApp(tester, 'm10-initial');
        await _normalizeLoggedOutState(tester);
        await _login(tester);
        await waitForKey(tester, const Key('bottom-nav-home'));

        final permissionStarted = DateTime.now();
        await tapFinderAndSettle(
          tester,
          find.text('扫码销售'),
          description: 'scan sales quick action',
        );
        await expectText(tester, '需要相机权限才能扫描条码');
        await enterText(
          tester,
          const Key('scanner-manual-input'),
          RimsE2eConfig.injectedBarcode,
        );
        await tapAndSettle(tester, const Key('scanner-manual-submit'));
        await waitForKey(tester, const Key('document-create-button'));
        final documents = await _documentsViewModel(tester);
        final stockBefore = await _stockQuantities(documents);
        await waitUntil(
          tester,
          description: 'manual scan draft line',
          condition: () => documents.draftLines.length == 1,
        );
        segments['permissionBoundary'] = DateTime.now()
            .difference(permissionStarted)
            .inMilliseconds;

        final scanStarted = DateTime.now();
        await tapAndSettle(tester, const Key('document-scan-product-button'));
        await expectText(tester, '需要相机权限才能扫描条码');
        final lookupStarted = DateTime.now();
        await tester.tap(find.byKey(const Key('scanner-permission-retry')));
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const Key('scanner-lookup-progress')).hitTestable(),
          findsOneWidget,
        );
        final scanFeedbackMs = DateTime.now()
            .difference(lookupStarted)
            .inMilliseconds;
        expect(scanFeedbackMs, lessThanOrEqualTo(250));
        segments['scanFeedback'] = scanFeedbackMs;
        await settleBounded(tester);
        await waitForKey(tester, const Key('document-create-button'));
        final barcodeLookupMs = DateTime.now()
            .difference(lookupStarted)
            .inMilliseconds;
        expect(barcodeLookupMs, lessThanOrEqualTo(2000));
        segments['barcodeLookup'] = barcodeLookupMs;
        await waitUntil(
          tester,
          description: 'duplicate scan quantity accumulation',
          condition: () =>
              documents.draftLines.length == 1 &&
              documents.draftLines.single.quantity == 2,
        );
        segments['cameraLifecycle'] = DateTime.now()
            .difference(scanStarted)
            .inMilliseconds;

        await _addProductBySku(
          tester,
          documents,
          sku: 'M9-PAGE-0004',
          quantity: 1,
        );
        expect(documents.draftLines.length, 2);

        final documentStarted = DateTime.now();
        final remark = 'M10-E2E:$runId:sales';
        await enterText(tester, const Key('document-remark-field'), remark);
        await scrollUntilVisible(
          tester,
          const Key('document-create-button'),
          scrollable: find.byKey(const Key('documents-scroll-view')),
        );
        await tapAndSettle(tester, const Key('document-create-button'));
        await waitUntil(
          tester,
          description: 'M10 sales document creation',
          condition: () => documents.recentDocuments.any(
            (document) => document.remark == remark,
          ),
        );
        final created = documents.recentDocuments.firstWhere(
          (document) => document.remark == remark,
        );
        final completeKey = Key('document-complete-${created.id}');
        await scrollUntilVisible(
          tester,
          completeKey,
          scrollable: find.byKey(const Key('documents-scroll-view')),
        );
        await tapAndSettle(tester, completeKey);
        await tapFinderAndSettle(
          tester,
          find.widgetWithText(FilledButton, '确认完成'),
          description: 'confirm M10 sales document',
        );
        await waitUntil(
          tester,
          description: 'M10 sales completion and transaction',
          condition: () =>
              documents.recentDocuments.any(
                (document) =>
                    document.id == created.id && document.status == '已完成',
              ) &&
              documents.transactions.any((item) => item.docId == created.id),
        );
        segments['documentSubmission'] = DateTime.now()
            .difference(documentStarted)
            .inMilliseconds;
        final stockAfterSales = await _stockQuantities(documents);
        expect(
          stockAfterSales['M9-PAGE-0001'],
          stockBefore['M9-PAGE-0001']! - 2,
        );
        expect(
          stockAfterSales['M9-PAGE-0004'],
          stockBefore['M9-PAGE-0004']! - 1,
        );

        final inbound = await _createMultiLineInbound(
          tester,
          documents,
          runId: runId,
        );
        final stockAfterInbound = await _stockQuantities(documents);
        expect(
          stockAfterInbound['M9-PAGE-0001'],
          stockAfterSales['M9-PAGE-0001']! + 1,
        );
        expect(
          stockAfterInbound['M9-PAGE-0004'],
          stockAfterSales['M9-PAGE-0004']! + 2,
        );

        final itemKey = Key('document-list-item-${created.id}');
        await scrollUntilVisible(
          tester,
          itemKey,
          scrollable: find.byKey(const Key('documents-scroll-view')),
        );
        await tester.tap(find.byKey(itemKey));
        await settleBounded(tester);
        await waitForKey(tester, const Key('attachment-panel'));

        final uploadStarted = DateTime.now();
        await tester.tap(find.byTooltip('选择文件'));
        final transfer = await _waitForTransfer(tester);
        final transferKey = tester.widget(transfer).key;
        segments['uploadFirstProgress'] = DateTime.now()
            .difference(uploadStarted)
            .inMilliseconds;
        tester
            .widget<AttachmentPanel>(find.byType(AttachmentPanel))
            .viewModel
            .pause();
        await tester.pump();
        await waitUntil(
          tester,
          description: 'interrupted upload state',
          condition: () => find.byTooltip('重试上传').evaluate().isNotEmpty,
        );

        await _pumpFreshApp(tester, 'm10-upload-recreation');
        await waitForKey(tester, const Key('bottom-nav-home'));
        await tapAndSettle(tester, const Key('bottom-nav-documents'));
        await _openDocumentDetailById(tester, created.id);
        await waitUntil(
          tester,
          description: 'recovered staged upload with stable request id',
          condition: () =>
              transferKey != null &&
              find.byKey(transferKey).evaluate().isNotEmpty,
        );
        await tapFinderAndSettle(
          tester,
          find.byTooltip('重试上传'),
          description: 'retry recovered upload',
        );
        await waitUntil(
          tester,
          description: 'uploaded document attachment',
          condition: () => find.byTooltip('附件操作').evaluate().isNotEmpty,
        );
        final attachments = tester
            .widget<AttachmentPanel>(find.byType(AttachmentPanel))
            .viewModel;
        expect(attachments.attachments, hasLength(1));
        final uploadedHash = attachments.attachments.single.fileHash;
        expect(uploadedHash, matches(RegExp(r'^[0-9a-f]{64}$')));
        final uploadTotal = DateTime.now()
            .difference(uploadStarted)
            .inMilliseconds;
        segments['uploadTotal'] = uploadTotal;

        await tester.tap(find.byTooltip('附件操作'));
        await tester.pumpAndSettle();
        await tapFinderAndSettle(
          tester,
          find.text('替换'),
          description: 'replace attachment',
        );
        await waitUntil(
          tester,
          description: 'replacement upload settled',
          condition: () => !attachments.isBusy,
        );
        expect(attachments.attachments, hasLength(1));
        final replacementHash = attachments.attachments.single.fileHash;
        expect(replacementHash, matches(RegExp(r'^[0-9a-f]{64}$')));
        await tester.tap(find.byTooltip('附件操作'));
        await tester.pumpAndSettle();
        await tapFinderAndSettle(
          tester,
          find.text('删除'),
          description: 'delete attachment',
        );
        await tapFinderAndSettle(
          tester,
          find.widgetWithText(FilledButton, '删除'),
          description: 'confirm attachment delete',
        );
        await waitUntil(
          tester,
          description: 'attachment deletion',
          condition: () => find.byTooltip('附件操作').evaluate().isEmpty,
        );
        expect(attachments.attachments, isEmpty);

        final report = <String, Object?>{
          'runId': runId,
          'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
          'segmentsMs': segments,
          'documentId': created.id,
          'documentNumber': created.number,
          'inboundDocumentId': inbound.id,
          'inboundDocumentNumber': inbound.number,
          'stockEffects': {
            'before': stockBefore,
            'afterSales': stockAfterSales,
            'afterInbound': stockAfterInbound,
          },
          'attachmentEvidence': {
            'uploadedCount': 1,
            'uploadedHash': uploadedHash,
            'replacementCount': 1,
            'replacementHash': replacementHash,
            'finalCount': attachments.attachments.length,
          },
          'permissionBoundary': 'deny-guidance+manual-fallback+retry',
          'realCameraAccess': 'verified-post-install-by-android-wrapper',
          'processRecreation': 'staged-upload-recovered-with-stable-request-id',
        };
        binding.reportData = report;
        debugPrint('RIMS_E2E_RESULT ${jsonEncode(report)}');
        await tester.pump(const Duration(seconds: 1));
      },
    );
  });
}

Future<Map<String, int>> _stockQuantities(DocumentsViewModel viewModel) async {
  const skus = ['M9-PAGE-0001', 'M9-PAGE-0004'];
  final repository = viewModel.inventoryRepository;
  if (repository == null) throw TestFailure('Inventory repository is missing.');
  final quantities = <String, int>{};
  for (final sku in skus) {
    final result = await repository.listInventory(keyword: sku);
    result.when(
      success: (page) {
        quantities[sku] = page.items
            .singleWhere((item) => item.sku == sku)
            .stockQuantity;
      },
      failure: (failure) {
        throw TestFailure(
          'Inventory lookup failed for $sku: ${failure.message}',
        );
      },
    );
  }
  return quantities;
}

Future<void> _pumpFreshApp(WidgetTester tester, String instance) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pumpWidget(MainApp(key: ValueKey<String>(instance)));
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
      final enabled =
          username.evaluate().isNotEmpty &&
          tester.widget<TextField>(username).enabled == true;
      if (!enabled) {
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
  await scrollUntilVisible(tester, const Key('profile-logout-button'));
  await tapAndSettle(tester, const Key('profile-logout-button'));
  await waitForKey(tester, const Key('login-username-field'));
}

Future<void> _login(WidgetTester tester) async {
  await enterText(
    tester,
    const Key('login-username-field'),
    RimsE2eConfig.adminUsername,
  );
  await enterText(
    tester,
    const Key('login-password-field'),
    RimsE2eConfig.adminPassword,
  );
  await tapFinderAndSettle(
    tester,
    find.widgetWithText(FilledButton, '登录'),
    description: 'admin login',
  );
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

Future<Finder> _waitForTransfer(WidgetTester tester) async {
  final finder = find.byWidgetPredicate(
    (widget) =>
        widget.key?.toString().contains('attachment-transfer-') ?? false,
  );
  for (var attempt = 0; attempt < 200; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 1));
    if (finder.evaluate().isNotEmpty) return finder.first;
  }
  throw TestFailure('Timed out waiting for the staged upload row.');
}

Future<void> _openDocumentDetailById(
  WidgetTester tester,
  int documentId,
) async {
  final viewModel = await _documentsViewModel(tester);
  await waitUntil(
    tester,
    description: 'reloaded document $documentId',
    condition: () =>
        !viewModel.isLoading &&
        viewModel.recentDocuments.any((document) => document.id == documentId),
  );
  final itemKey = Key('document-list-item-$documentId');
  await scrollUntilVisible(
    tester,
    itemKey,
    scrollable: find.byKey(const Key('documents-scroll-view')),
  );
  await tester.tap(find.byKey(itemKey));
  await settleBounded(tester);
  await waitForKey(tester, const Key('attachment-panel'));
}

Future<void> _addProductBySku(
  WidgetTester tester,
  DocumentsViewModel viewModel, {
  required String sku,
  required int quantity,
}) async {
  final scroll = find.byKey(const Key('documents-scroll-view'));
  await scrollUntilVisible(
    tester,
    const Key('document-product-field'),
    scrollable: scroll,
  );
  await enterText(tester, const Key('document-product-field'), sku);
  await waitUntil(
    tester,
    description: 'product candidate $sku',
    condition: () =>
        viewModel.productCandidates.any((candidate) => candidate.sku == sku),
  );
  final candidate = viewModel.productCandidates.singleWhere(
    (product) => product.sku == sku,
  );
  final candidateKey = Key('document-product-option-${candidate.productId}');
  await scrollUntilVisible(tester, candidateKey, scrollable: scroll);
  await tapAndSettle(tester, candidateKey);
  await enterText(
    tester,
    const Key('document-quantity-field'),
    quantity.toString(),
  );
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 200));
  final before = viewModel.draftLines.length;
  await scrollUntilVisible(
    tester,
    const Key('document-add-line-button'),
    scrollable: scroll,
  );
  await tapAndSettle(tester, const Key('document-add-line-button'));
  await waitUntil(
    tester,
    description: 'draft line $sku',
    condition: () => viewModel.draftLines.length == before + 1,
  );
}

Future<({int id, String number})> _createMultiLineInbound(
  WidgetTester tester,
  DocumentsViewModel viewModel, {
  required String runId,
}) async {
  final scroll = find.byKey(const Key('documents-scroll-view'));
  await scrollUntilVisible(
    tester,
    const Key('document-action-inbound'),
    scrollable: scroll,
    delta: 300,
  );
  await tapAndSettle(tester, const Key('document-action-inbound'));
  await _addProductBySku(
    tester,
    viewModel,
    sku: RimsE2eConfig.fixtureProductCode,
    quantity: 1,
  );
  await _addProductBySku(tester, viewModel, sku: 'M9-PAGE-0004', quantity: 2);
  final remark = 'M10-E2E:$runId:inbound';
  await enterText(tester, const Key('document-remark-field'), remark);
  final existingIds = viewModel.recentDocuments
      .map((document) => document.id)
      .toSet();
  await scrollUntilVisible(
    tester,
    const Key('document-create-button'),
    scrollable: scroll,
  );
  await tapAndSettle(tester, const Key('document-create-button'));
  await waitUntil(
    tester,
    description: 'multi-line inbound creation',
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
  await scrollUntilVisible(tester, completeKey, scrollable: scroll);
  await tapAndSettle(tester, completeKey);
  await tapFinderAndSettle(
    tester,
    find.widgetWithText(FilledButton, '确认完成'),
    description: 'confirm multi-line inbound',
  );
  await waitUntil(
    tester,
    description: 'multi-line inbound completion and transaction',
    condition: () =>
        viewModel.recentDocuments.any(
          (document) => document.id == created.id && document.status == '已完成',
        ) &&
        viewModel.transactions.any((item) => item.docId == created.id),
  );
  return (id: created.id, number: created.number);
}
