import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rims_frontend/app.dart';
import 'package:rims_frontend/features/documents/presentation/view_models/documents_view_model.dart';
import 'package:rims_frontend/features/inventory/presentation/view_models/inventory_view_model.dart';
import 'package:rims_frontend/features/offline/data/bootstrap/offline_store_bootstrap.dart';
import 'package:rims_frontend/features/offline/data/database/offline_database.dart';
import 'package:rims_frontend/features/offline/data/database/offline_database_factory.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/repositories/outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_ownership_service.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_store.dart';
import 'package:rims_frontend/features/offline/presentation/view_models/sync_center_view_model.dart';
import 'package:rims_frontend/features/reports/presentation/view_models/reports_view_model.dart';

import 'support/rims_e2e_config.dart';
import 'support/rims_e2e_driver.dart';

late final IntegrationTestWidgetsFlutterBinding binding;

void main() {
  binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('M11 Android offline synchronization journey', (tester) async {
    expect(RimsE2eConfig.m11Enabled, isTrue);
    expect(RimsE2eConfig.m11FaultControlUrl, startsWith('http://10.0.2.2:'));
    expect(RimsE2eConfig.m11FaultControlUrl, endsWith('/__rims_m11'));

    await screenshotOnFailure(binding, 'm11-offline-sync-failure', () async {
      final databaseCorruptionQuarantined = await _verifyCorruptionQuarantine();
      final store = await createOfflineStore();
      final outbox = outboxRepositoryForOfflineStore(store);
      final runId = DateTime.now().microsecondsSinceEpoch.toString();
      final remarks = _JourneyRemarks(runId);
      final operationIds = <String>[];
      final idempotencyHashes = <String>[];
      var accountId = '';
      var stockBefore = 0;
      var stockAfter = 0;
      var cacheReadLatencyMs = 0;
      var draftSaveLatencyMs = 0;
      var processRecoveryLatencyMs = 0;
      var outboxEnqueueLatencyMs = 0;
      var syncTotalMs = 0;
      var attachmentHash = '';
      var attachmentCount = 0;
      var unknownResponseProbed = false;
      var duplicateSingleEffect = false;
      var attachmentDependencyCompleted = false;
      var staleSessionBlocked = false;
      var stalePermissionBlocked = false;
      var conflictVisible = false;
      var conflictResolved = false;
      var logoutCleanupCompleted = false;
      var baselineRestored = false;

      try {
        await _fault('reset');
        await _pumpApp(tester, store, 'm11-initial');
        await _normalizeLoggedOutState(tester);
        await _login(tester);
        await waitForKey(tester, const Key('bottom-nav-home'));

        await tapAndSettle(tester, const Key('bottom-nav-inventory'));
        final inventory = await _viewModel<InventoryViewModel>(tester);
        await waitUntil(
          tester,
          description: 'online inventory seed',
          condition: () => !inventory.isLoading && inventory.items.isNotEmpty,
        );
        await tapAndSettle(tester, const Key('bottom-nav-reports'));
        final reports = await _viewModel<ReportsViewModel>(tester);
        await waitUntil(
          tester,
          description: 'online report seed',
          condition: () => !reports.isLoading,
        );
        await tapAndSettle(tester, const Key('bottom-nav-documents'));
        var documents = await _documentsViewModel(tester);
        await waitUntil(
          tester,
          description: 'online document seed',
          condition: () =>
              !documents.isLoading && documents.recentDocuments.isNotEmpty,
        );
        accountId = documents.accountId!;
        stockBefore = await _stockQuantity(documents);
        final cachedDetailId = documents.recentDocuments.first.id;
        await _openDocumentDetail(tester, cachedDetailId);
        await tester.pageBack();
        await settleBounded(tester);

        await _verifyLocalTransportFaults(tester);

        await _fault('airplane-mode', {'restoreMs': '3500'});
        await tester.pump(const Duration(milliseconds: 500));
        cacheReadLatencyMs = await _verifyCachedReads(
          tester,
          cachedDetailId: cachedDetailId,
        );
        expect(cacheReadLatencyMs, lessThanOrEqualTo(500));
        await tester.pump(const Duration(seconds: 4));
        await _fault('unreachable');

        await _returnToShell(tester);
        await tapAndSettle(tester, const Key('bottom-nav-documents'));
        documents = await _documentsViewModel(tester);
        await _prepareDraft(
          tester,
          documents,
          remark: remarks.queued,
          withAttachment: false,
        );
        final draftId = documents.activeDraftId!;
        final recoveredProductId = documents.draftLines.single.productId;
        final saveWatch = Stopwatch()..start();
        await documents.saveDraft();
        saveWatch.stop();
        draftSaveLatencyMs = saveWatch.elapsedMilliseconds;
        expect(draftSaveLatencyMs, lessThanOrEqualTo(250));

        final recoveryWatch = Stopwatch()..start();
        await _pumpApp(tester, store, 'm11-recreated');
        await waitForKey(tester, const Key('bottom-nav-home'));
        await tapAndSettle(tester, const Key('bottom-nav-documents'));
        documents = await _documentsViewModel(tester);
        expect(await documents.openDraft(draftId), isTrue);
        await waitForKey(
          tester,
          Key('document-draft-line-$recoveredProductId'),
          timeout: const Duration(seconds: 1),
        );
        recoveryWatch.stop();
        processRecoveryLatencyMs = recoveryWatch.elapsedMilliseconds;
        expect(processRecoveryLatencyMs, lessThanOrEqualTo(1000));

        final beforeQueued = await _operations(outbox, accountId);
        final enqueueWatch = Stopwatch()..start();
        final queuedCreate = await _queueCurrentDraft(documents, beforeQueued);
        enqueueWatch.stop();
        outboxEnqueueLatencyMs = enqueueWatch.elapsedMilliseconds;
        expect(outboxEnqueueLatencyMs, lessThanOrEqualTo(250));
        _recordOperation(queuedCreate, operationIds, idempotencyHashes);

        await _fault('reset');
        final queuedSyncWatch = Stopwatch()..start();
        await _syncOperation(tester, queuedCreate.operationId);
        queuedSyncWatch.stop();
        syncTotalMs = _max(syncTotalMs, queuedSyncWatch.elapsedMilliseconds);
        expect(
          (await _operation(outbox, accountId, queuedCreate.operationId)).state,
          OutboxState.succeeded,
        );

        await _returnToShell(tester);
        await tapAndSettle(tester, const Key('bottom-nav-documents'));
        documents = await _documentsViewModel(tester);
        await _prepareDraft(
          tester,
          documents,
          remark: remarks.unknown,
          withAttachment: false,
        );
        final beforeUnknown = await _operations(outbox, accountId);
        await _fault('unknown-response');
        expect(await documents.createDocument(), isFalse);
        final unknownSnapshot = documents.offlineSubmissionSnapshot;
        expect(unknownSnapshot, isNotNull);
        expect(
          await documents.confirmOfflineSubmission(unknownSnapshot!),
          isTrue,
        );
        final unknownCreate =
            (await _newOperations(
              outbox,
              accountId,
              beforeUnknown,
            )).singleWhere(
              (operation) =>
                  operation.kind == OutboxOperationKind.documentCreate,
            );
        expect(unknownCreate.requiresStatusProbe, isTrue);
        _recordOperation(unknownCreate, operationIds, idempotencyHashes);
        await _fault('reset');
        final unknownSyncWatch = Stopwatch()..start();
        await _syncOperation(tester, unknownCreate.operationId);
        unknownSyncWatch.stop();
        syncTotalMs = _max(syncTotalMs, unknownSyncWatch.elapsedMilliseconds);
        var current = await _operation(
          outbox,
          accountId,
          unknownCreate.operationId,
        );
        if (current.state != OutboxState.succeeded) {
          await _fault('duplicate-delivery');
          await _syncOperation(tester, unknownCreate.operationId);
          current = await _operation(
            outbox,
            accountId,
            unknownCreate.operationId,
          );
        }
        expect(current.state, OutboxState.succeeded);
        unknownResponseProbed = unknownCreate.requiresStatusProbe;

        await _fault('unreachable');
        await _returnToShell(tester);
        await tapAndSettle(tester, const Key('bottom-nav-documents'));
        documents = await _documentsViewModel(tester);
        await _prepareDraft(
          tester,
          documents,
          remark: remarks.attachment,
          withAttachment: true,
        );
        final beforeAttachment = await _operations(outbox, accountId);
        final attachmentCreate = await _queueCurrentDraft(
          documents,
          beforeAttachment,
        );
        final attachmentGraph = await _newOperations(
          outbox,
          accountId,
          beforeAttachment,
        );
        final upload = attachmentGraph.singleWhere(
          (operation) => operation.kind == OutboxOperationKind.attachmentUpload,
        );
        attachmentHash = upload.payload['expectedSha256']!.toString();
        attachmentCount = 1;
        for (final operation in attachmentGraph) {
          _recordOperation(operation, operationIds, idempotencyHashes);
        }
        await _fault('reset');
        await _fault('duplicate-delivery');
        final attachmentSyncWatch = Stopwatch()..start();
        await _syncOperation(tester, attachmentCreate.operationId);
        attachmentSyncWatch.stop();
        syncTotalMs = _max(
          syncTotalMs,
          attachmentSyncWatch.elapsedMilliseconds,
        );
        final attachmentStates = await Future.wait(
          attachmentGraph.map(
            (operation) => _operation(outbox, accountId, operation.operationId),
          ),
        );
        attachmentDependencyCompleted = attachmentStates.every(
          (operation) => operation.state == OutboxState.succeeded,
        );
        expect(attachmentDependencyCompleted, isTrue);

        await _returnToShell(tester);
        await tapAndSettle(tester, const Key('bottom-nav-documents'));
        documents = await _documentsViewModel(tester);
        await documents.load();
        final attachmentDocuments = documents.recentDocuments
            .where((document) => document.remark == remarks.attachment)
            .toList();
        duplicateSingleEffect = attachmentDocuments.length == 1;
        expect(duplicateSingleEffect, isTrue);
        final created = attachmentDocuments.single;
        await _fault('unreachable');
        final beforeLifecycle = await _operations(outbox, accountId);
        expect(
          documents.prepareOfflineLifecycleSubmission(
            created,
            OutboxOperationKind.documentComplete,
          ),
          isTrue,
        );
        final lifecycleSnapshot = documents.offlineSubmissionSnapshot;
        expect(lifecycleSnapshot, isNotNull);
        expect(
          await documents.confirmOfflineSubmission(lifecycleSnapshot!),
          isTrue,
        );
        final lifecycleGraph = await _newOperations(
          outbox,
          accountId,
          beforeLifecycle,
        );
        final lifecycle = lifecycleGraph.singleWhere(
          (operation) => operation.kind == OutboxOperationKind.documentComplete,
        );
        for (final operation in lifecycleGraph) {
          _recordOperation(operation, operationIds, idempotencyHashes);
        }
        await _fault('reset');
        final lifecycleWatch = Stopwatch()..start();
        await _syncOperation(tester, lifecycle.operationId);
        lifecycleWatch.stop();
        syncTotalMs = _max(syncTotalMs, lifecycleWatch.elapsedMilliseconds);
        expect(
          (await _operation(outbox, accountId, lifecycle.operationId)).state,
          OutboxState.succeeded,
        );

        await _fault('unreachable');
        await _returnToShell(tester);
        await tapAndSettle(tester, const Key('bottom-nav-documents'));
        documents = await _documentsViewModel(tester);
        await _prepareDraft(
          tester,
          documents,
          remark: remarks.conflict,
          withAttachment: false,
        );
        final beforeConflict = await _operations(outbox, accountId);
        final conflictOperation = await _queueCurrentDraft(
          documents,
          beforeConflict,
        );
        _recordOperation(conflictOperation, operationIds, idempotencyHashes);
        await _fault('reset');
        await _fault('server-conflict');
        await _syncOperation(tester, conflictOperation.operationId);
        final conflicted = await _operation(
          outbox,
          accountId,
          conflictOperation.operationId,
        );
        conflictVisible = conflicted.state == OutboxState.conflict;
        expect(conflictVisible, isTrue);
        final syncCenter = await _syncCenterViewModel(tester);
        await syncCenter.discard(conflicted.operationId);
        conflictResolved = !(await _operations(
          outbox,
          accountId,
        )).any((operation) => operation.operationId == conflicted.operationId);
        expect(conflictResolved, isTrue);

        await _fault('unreachable');
        await _returnToShell(tester);
        await tapAndSettle(tester, const Key('bottom-nav-documents'));
        documents = await _documentsViewModel(tester);
        await _prepareDraft(
          tester,
          documents,
          remark: remarks.staleContext,
          withAttachment: false,
        );
        final beforeStale = await _operations(outbox, accountId);
        final staleOperation = await _queueCurrentDraft(documents, beforeStale);
        _recordOperation(staleOperation, operationIds, idempotencyHashes);
        await _fault('reset');
        await _fault('stale-session');
        await _syncOperation(tester, staleOperation.operationId);
        await waitForKey(tester, const Key('login-username-field'));
        staleSessionBlocked =
            (await _operation(
              outbox,
              accountId,
              staleOperation.operationId,
            )).state ==
            OutboxState.retryableFailure;
        expect(staleSessionBlocked, isTrue);
        await _login(tester);
        await waitForKey(tester, const Key('bottom-nav-home'));
        await _fault('stale-permission');
        await _syncOperation(tester, staleOperation.operationId);
        final permissionBlocked = await _operation(
          outbox,
          accountId,
          staleOperation.operationId,
        );
        final staleSyncCenter = await _syncCenterViewModel(tester);
        stalePermissionBlocked =
            permissionBlocked.state == OutboxState.permanentFailure &&
            staleSyncCenter.attention.any(
              (operation) =>
                  operation.operationId == staleOperation.operationId,
            );
        expect(stalePermissionBlocked, isTrue);
        await _fault('reset');

        await _returnToShell(tester);
        await tapAndSettle(tester, const Key('bottom-nav-documents'));
        documents = await _documentsViewModel(tester);
        await documents.load();
        stockAfter = await _stockQuantity(documents);
        final serverDocumentCount = documents.recentDocuments
            .where((document) => document.remark == remarks.unknown)
            .length;
        final transactionCount = documents.transactions
            .where((transaction) => transaction.docId == created.id)
            .length;
        final duplicateDocumentCount =
            <String>[
              remarks.queued,
              remarks.unknown,
              remarks.attachment,
            ].fold<int>(0, (duplicates, remark) {
              final count = documents.recentDocuments
                  .where((document) => document.remark == remark)
                  .length;
              return duplicates + (count > 1 ? count - 1 : 0);
            });
        expect(serverDocumentCount, 1);
        expect(duplicateDocumentCount, 0);
        expect(transactionCount, 1);
        expect(syncTotalMs, lessThanOrEqualTo(10000));

        final databaseBytes = await _databaseBytes();
        expect(databaseBytes, lessThanOrEqualTo(25 * 1024 * 1024));
        await tapAndSettle(tester, const Key('bottom-nav-profile'));
        await scrollUntilVisible(tester, const Key('profile-logout-button'));
        await tapAndSettle(tester, const Key('profile-logout-button'));
        await tapAndSettle(tester, const Key('profile-logout-delete-drafts'));
        await waitForKey(tester, const Key('login-username-field'));
        final ownershipStore = store as OfflineOwnershipStore;
        final cleanupSnapshot = await ownershipStore.inspectAccount(accountId);
        logoutCleanupCompleted =
            cleanupSnapshot.cacheEntries == 0 &&
            cleanupSnapshot.drafts == 0 &&
            cleanupSnapshot.outboxOperations == 0 &&
            cleanupSnapshot.draftAttachmentRequestIds.isEmpty;
        expect(logoutCleanupCompleted, isTrue);
        await _fault('reset');
        baselineRestored = true;

        final evidence = <String, Object?>{
          'cacheReadLatencyMs': cacheReadLatencyMs,
          'draftSaveLatencyMs': draftSaveLatencyMs,
          'processRecoveryLatencyMs': processRecoveryLatencyMs,
          'outboxEnqueueLatencyMs': outboxEnqueueLatencyMs,
          'syncTotalMs': syncTotalMs,
          'intentionalFaultDelayMs': 3500,
          'operationIds': operationIds,
          'idempotencyKeyHashes': idempotencyHashes,
          'stockBefore': stockBefore,
          'stockAfter': stockAfter,
          'serverDocumentCount': serverDocumentCount,
          'duplicateDocumentCount': duplicateDocumentCount,
          'duplicateInventoryTransactionCount': transactionCount - 1,
          'attachmentHash': attachmentHash,
          'attachmentCount': attachmentCount,
          'databaseBytes': databaseBytes,
          'cleanup': <String, bool>{
            'accountCacheCleared': logoutCleanupCompleted,
            'outboxCleared': cleanupSnapshot.outboxOperations == 0,
            'stagingCleared': cleanupSnapshot.draftAttachmentRequestIds.isEmpty,
            'baselineRestored': baselineRestored,
          },
          'journey': <String, bool>{
            'onlineSeeded': true,
            'cachedInventoryRead': true,
            'cachedReportRead': true,
            'cachedDetailRead': true,
            'draftRecovered': true,
            'explicitSyncConfirmed': true,
            'unknownResponseProbed': unknownResponseProbed,
            'idempotentReplaySingleEffect': duplicateSingleEffect,
            'attachmentDependencyCompleted': attachmentDependencyCompleted,
            'staleSessionBlocked': staleSessionBlocked,
            'stalePermissionBlocked': stalePermissionBlocked,
            'conflictVisible': conflictVisible,
            'conflictResolved': conflictResolved,
            'logoutCleanupCompleted': logoutCleanupCompleted,
            'databaseCorruptionQuarantined': databaseCorruptionQuarantined,
          },
        };
        binding.reportData = evidence;
        debugPrint('RIMS_E2E_RESULT ${jsonEncode(evidence)}');
        await tester.pump(const Duration(seconds: 1));
      } finally {
        try {
          await _fault('reset');
        } on Object {
          // The host wrapper performs a second, authoritative reset in finally.
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        if (store is OfflineDatabase) await store.close();
      }
    });
  });
}

final class _JourneyRemarks {
  const _JourneyRemarks(this.runId);

  final String runId;
  String get queued => 'M11-E2E:$runId:queued';
  String get unknown => 'M11-E2E:$runId:unknown';
  String get attachment => 'M11-E2E:$runId:attachment';
  String get conflict => 'M11-E2E:$runId:conflict';
  String get staleContext => 'M11-E2E:$runId:stale-context';
}

Future<void> _fault(
  String action, [
  Map<String, String> parameters = const {},
]) async {
  final base = Uri.parse(RimsE2eConfig.m11FaultControlUrl);
  final uri = base.replace(queryParameters: {'action': action, ...parameters});
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 5));
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode != HttpStatus.ok) {
      throw TestFailure(
        'Fault control $action failed: ${response.statusCode}.',
      );
    }
    final result = jsonDecode(body) as Map<String, dynamic>;
    expect(result['ok'], isTrue, reason: 'fault control $action');
  } finally {
    client.close(force: true);
  }
}

Future<void> _verifyLocalTransportFaults(WidgetTester tester) async {
  try {
    await _fault('latency', {'delayMs': '150'});
    final watch = Stopwatch()..start();
    await _probeBackendHealth();
    watch.stop();
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(100));
  } finally {
    await _fault('reset');
  }

  try {
    await _fault('packet-loss');
    await expectLater(_probeBackendHealth(), throwsA(isA<Object>()));
  } finally {
    await _fault('reset');
  }

  await _fault('wifi-switch', {'restoreMs': '1000'});
  await Future<void>.delayed(const Duration(milliseconds: 1400));
  await tester.pump();
  await _probeBackendHealth();
}

Future<void> _probeBackendHealth() async {
  final control = Uri.parse(RimsE2eConfig.m11FaultControlUrl);
  final health = control.replace(path: '/healthz', query: null);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final request = await client.getUrl(health);
    final response = await request.close().timeout(const Duration(seconds: 3));
    await response.drain<void>();
    if (response.statusCode != HttpStatus.ok) {
      throw TestFailure(
        'Backend health probe returned ${response.statusCode}.',
      );
    }
  } finally {
    client.close(force: true);
  }
}

Future<void> _pumpApp(
  WidgetTester tester,
  OfflineStore store,
  String instance,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pumpWidget(
    MainApp(key: ValueKey(instance), offlineStore: store),
  );
  await tester.pump();
}

Future<void> _normalizeLoggedOutState(WidgetTester tester) async {
  await waitUntil(
    tester,
    description: 'login form or restored shell',
    condition: () =>
        find.byKey(const Key('login-username-field')).evaluate().isNotEmpty ||
        find.byKey(const Key('bottom-nav-home')).evaluate().isNotEmpty,
  );
  if (find.byKey(const Key('bottom-nav-home')).evaluate().isEmpty) return;
  await tapAndSettle(tester, const Key('bottom-nav-profile'));
  await scrollUntilVisible(tester, const Key('profile-logout-button'));
  await tapAndSettle(tester, const Key('profile-logout-button'));
  await tapAndSettle(tester, const Key('profile-logout-delete-drafts'));
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

Future<T> _viewModel<T extends ChangeNotifier>(WidgetTester tester) async {
  final finder = find.byWidgetPredicate(
    (widget) => widget is AnimatedBuilder && widget.animation is T,
  );
  await waitUntil(
    tester,
    description: '$T view model',
    condition: () => finder.evaluate().isNotEmpty,
  );
  return tester.widget<AnimatedBuilder>(finder.first).animation as T;
}

Future<DocumentsViewModel> _documentsViewModel(WidgetTester tester) =>
    _viewModel<DocumentsViewModel>(tester);

Future<SyncCenterViewModel> _syncCenterViewModel(WidgetTester tester) =>
    _viewModel<SyncCenterViewModel>(tester);

Future<void> _returnToShell(WidgetTester tester) async {
  while (find.byKey(const Key('bottom-nav-home')).evaluate().isEmpty) {
    await tester.pageBack();
    await settleBounded(tester);
  }
}

Future<int> _verifyCachedReads(
  WidgetTester tester, {
  required int cachedDetailId,
}) async {
  final latencies = <int>[];
  for (final target in <({Key nav, Key cache})>[
    (
      nav: const Key('bottom-nav-inventory'),
      cache: const Key('inventory-cache-status'),
    ),
    (
      nav: const Key('bottom-nav-reports'),
      cache: const Key('reports-cache-status'),
    ),
    (
      nav: const Key('bottom-nav-documents'),
      cache: const Key('documents-cache-status'),
    ),
  ]) {
    final watch = Stopwatch()..start();
    await tester.tap(find.byKey(target.nav));
    await tester.pump();
    await waitForKey(
      tester,
      target.cache,
      timeout: const Duration(milliseconds: 500),
    );
    watch.stop();
    latencies.add(watch.elapsedMilliseconds);
  }
  final detailWatch = Stopwatch()..start();
  await _openDocumentDetail(tester, cachedDetailId);
  detailWatch.stop();
  latencies.add(detailWatch.elapsedMilliseconds);
  await tester.pageBack();
  await settleBounded(tester);
  return latencies.reduce((left, right) => left > right ? left : right);
}

Future<void> _openDocumentDetail(WidgetTester tester, int documentId) async {
  final key = Key('document-list-item-$documentId');
  await scrollUntilVisible(
    tester,
    key,
    scrollable: find.byKey(const Key('documents-scroll-view')),
  );
  await tester.tap(find.byKey(key));
  await tester.pump();
  await waitUntil(
    tester,
    description: 'document detail $documentId',
    condition: () =>
        find.byKey(const Key('document-detail-loading')).evaluate().isEmpty &&
        find.byKey(const Key('document-detail-error')).evaluate().isEmpty,
  );
}

Future<void> _prepareDraft(
  WidgetTester tester,
  DocumentsViewModel documents, {
  required String remark,
  required bool withAttachment,
}) async {
  await _addProductBySku(tester, documents, RimsE2eConfig.fixtureProductCode);
  await enterText(tester, const Key('document-remark-field'), remark);
  if (withAttachment) {
    await scrollUntilVisible(
      tester,
      const Key('document-draft-attachment-file'),
      scrollable: find.byKey(const Key('documents-scroll-view')),
    );
    await tapAndSettle(tester, const Key('document-draft-attachment-file'));
    await waitUntil(
      tester,
      description: 'staged M11 attachment',
      condition: () => documents.attachmentStagingIds.length == 1,
    );
  }
}

Future<void> _addProductBySku(
  WidgetTester tester,
  DocumentsViewModel documents,
  String sku,
) async {
  final scroll = find.byKey(const Key('documents-scroll-view'));
  await scrollUntilVisible(
    tester,
    const Key('document-product-field'),
    scrollable: scroll,
  );
  await enterText(tester, const Key('document-product-field'), sku);
  await waitUntil(
    tester,
    description: 'cached product $sku',
    condition: () => documents.productCandidates.any((item) => item.sku == sku),
  );
  final product = documents.productCandidates.singleWhere(
    (item) => item.sku == sku,
  );
  await tapAndSettle(
    tester,
    Key('document-product-option-${product.productId}'),
  );
  await enterText(tester, const Key('document-quantity-field'), '1');
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 20));
  await scrollUntilVisible(
    tester,
    const Key('document-add-line-button'),
    scrollable: scroll,
  );
  await tapAndSettle(tester, const Key('document-add-line-button'));
  await waitUntil(
    tester,
    description: 'M11 draft line',
    condition: () => documents.draftLines.isNotEmpty,
  );
}

Future<OutboxOperation> _queueCurrentDraft(
  DocumentsViewModel documents,
  List<OutboxOperation> before,
) async {
  expect(await documents.prepareOfflineSubmission(), isTrue);
  final snapshot = documents.offlineSubmissionSnapshot;
  expect(snapshot, isNotNull);
  expect(await documents.confirmOfflineSubmission(snapshot!), isTrue);
  final after = await _operations(
    documents.outboxRepository!,
    documents.accountId!,
  );
  final previousIds = before.map((operation) => operation.operationId).toSet();
  return after.singleWhere(
    (operation) =>
        !previousIds.contains(operation.operationId) &&
        operation.kind == OutboxOperationKind.documentCreate,
  );
}

Future<void> _syncOperation(WidgetTester tester, String operationId) async {
  await _returnToShell(tester);
  await tapAndSettle(tester, const Key('bottom-nav-profile'));
  await scrollUntilVisible(tester, const Key('profile-sync-center-entry'));
  await tapAndSettle(tester, const Key('profile-sync-center-entry'));
  final viewModel = await _syncCenterViewModel(tester);
  await waitUntil(
    tester,
    description: 'sync center loaded',
    condition: () => !viewModel.isLoading,
  );
  await viewModel.reviewAndSync(operationId);
  await waitUntil(
    tester,
    description: 'sync command completed',
    condition: () => !viewModel.isBusy,
    timeout: const Duration(seconds: 12),
  );
}

Future<List<OutboxOperation>> _operations(
  OutboxRepository repository,
  String accountId,
) async {
  return (await repository.list(accountId)).when(
    success: (value) => value,
    failure: (failure) => throw TestFailure(failure.message),
  );
}

Future<List<OutboxOperation>> _newOperations(
  OutboxRepository repository,
  String accountId,
  List<OutboxOperation> before,
) async {
  final previous = before.map((operation) => operation.operationId).toSet();
  return (await _operations(
    repository,
    accountId,
  )).where((operation) => !previous.contains(operation.operationId)).toList();
}

Future<OutboxOperation> _operation(
  OutboxRepository repository,
  String accountId,
  String operationId,
) async {
  return (await _operations(
    repository,
    accountId,
  )).singleWhere((operation) => operation.operationId == operationId);
}

void _recordOperation(
  OutboxOperation operation,
  List<String> ids,
  List<String> hashes,
) {
  if (ids.contains(operation.operationId)) return;
  ids.add(operation.operationId);
  hashes.add(sha256.convert(utf8.encode(operation.idempotencyKey)).toString());
}

Future<int> _stockQuantity(DocumentsViewModel documents) async {
  final result = await documents.inventoryRepository!.listInventory(
    keyword: RimsE2eConfig.fixtureProductCode,
  );
  return result.when(
    success: (page) => page.items
        .singleWhere((item) => item.sku == RimsE2eConfig.fixtureProductCode)
        .stockQuantity,
    failure: (failure) => throw TestFailure(failure.message),
  );
}

Future<int> _databaseBytes() async {
  final directory = await getApplicationSupportDirectory();
  var bytes = 0;
  await for (final entity in directory.list()) {
    if (entity is File && entity.path.contains('rims_offline.sqlite')) {
      bytes += await entity.length();
    }
  }
  return bytes;
}

Future<bool> _verifyCorruptionQuarantine() async {
  final root = await Directory.systemTemp.createTemp('rims-m11-corrupt-');
  final path = '${root.path}${Platform.pathSeparator}m11-corrupt.sqlite';
  try {
    await File(path).writeAsBytes(const [0x52, 0x49, 0x4d, 0x53]);
    final factory = OfflineDatabaseFactory(
      readKey: () async => '1' * 64,
      writeKey: (_) async {},
      now: () => DateTime.utc(2026, 7, 14),
    );
    final database = await factory.openNative(path);
    await database.close();
    final quarantined = await root
        .list()
        .where((entity) => entity.path.startsWith('$path.corrupt-'))
        .toList();
    return quarantined.length == 1 && await File(path).exists();
  } finally {
    final candidate = root.absolute.path;
    final temp = Directory.systemTemp.absolute.path;
    if (candidate.startsWith(temp) && candidate != temp) {
      await root.delete(recursive: true);
    }
  }
}

int _max(int left, int right) => left > right ? left : right;
