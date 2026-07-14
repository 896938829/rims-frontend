import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rims_frontend/app.dart';
import 'package:rims_frontend/features/attachments/presentation/view_models/attachments_view_model.dart';
import 'package:rims_frontend/features/documents/presentation/view_models/documents_view_model.dart';
import 'package:rims_frontend/features/inventory/presentation/view_models/inventory_view_model.dart';
import 'package:rims_frontend/features/offline/data/bootstrap/offline_store_bootstrap.dart';
import 'package:rims_frontend/features/offline/data/database/offline_database.dart';
import 'package:rims_frontend/features/offline/data/database/offline_database_factory.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/repositories/outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_ownership_service.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_store.dart';
import 'package:rims_frontend/features/offline/presentation/pages/sync_center_page.dart';
import 'package:rims_frontend/features/offline/presentation/view_models/sync_center_view_model.dart';
import 'package:rims_frontend/features/reports/presentation/view_models/reports_view_model.dart';
import 'package:rims_frontend/features/shell/presentation/pages/app_shell_page.dart';

import 'support/m11_fault_control.dart';
import 'support/m11_journey_fixtures.dart';
import 'support/rims_e2e_config.dart';
import 'support/rims_e2e_driver.dart';

late final IntegrationTestWidgetsFlutterBinding binding;

void main() {
  binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('M11 Android offline synchronization journey', (tester) async {
    if (!RimsE2eConfig.m11Enabled || !RimsE2eConfig.m11StageOrchestrated) {
      return;
    }
    expect(RimsE2eConfig.m11FaultControlUrl, startsWith('http://10.0.2.2:'));
    expect(RimsE2eConfig.m11FaultControlUrl, endsWith('/__rims_m11'));

    await screenshotOnFailure(binding, 'm11-offline-sync-failure', () async {
      const processRecoveryBoundary = 'draft-manager-frame-before-open-command';
      final expectedStage = RimsE2eConfig.m11ProcessStage;
      expect(const {
        'seed',
        'offline-draft',
        'recovery',
      }, contains(expectedStage));
      final checkpointFile = await _checkpointFile();
      if (expectedStage == 'seed' && await checkpointFile.exists()) {
        await checkpointFile.delete();
      }
      final checkpoint = await _readCheckpoint(checkpointFile);
      final nextStage = checkpoint?['nextStage']?.toString() ?? 'seed';
      expect(nextStage, expectedStage);
      final store = await createOfflineStore();
      final outbox = outboxRepositoryForOfflineStore(store);
      final runId =
          checkpoint?['runId']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString();
      final remarks = _JourneyRemarks(runId);
      final operationIds = <String>[];
      final idempotencyHashes = <String>[];
      var accountId = checkpoint?['accountId']?.toString() ?? '';
      var salesProductSku = checkpoint?['salesProductSku']?.toString() ?? '';
      var stockBefore = (checkpoint?['stockBefore'] as num?)?.toInt() ?? 0;
      var stockAfter = 0;
      var cacheReadLatencyMs =
          (checkpoint?['cacheReadLatencyMs'] as num?)?.toInt() ?? 0;
      var draftSaveLatencyMs =
          (checkpoint?['draftSaveLatencyMs'] as num?)?.toInt() ?? 0;
      var draftAutosaveEndToEndMs =
          (checkpoint?['draftAutosaveEndToEndMs'] as num?)?.toInt() ?? 0;
      const draftAutosaveDebounceMs = 300;
      var processRecoveryLatencyMs = 0;
      var outboxEnqueueLatencyMs = 0;
      var syncTotalMs = 0;
      var attachmentHash = '';
      var attachmentCount = 0;
      var unknownResponseProbed = false;
      var unknownStatusProbeCount = 0;
      var unknownReplayRequestCount = 0;
      var unknownIdempotencyKeyHash = '';
      var unknownRequestFingerprintHash = '';
      var unknownSameTargetReplayObserved = false;
      var duplicateSingleEffect = false;
      var attachmentDependencyCompleted = false;
      var staleSessionBlocked = false;
      var stalePermissionBlocked = false;
      var conflictVisible = false;
      var conflictResolved = false;
      var conflictReplacementCreated = false;
      var conflictReplacementVisible = false;
      var logoutCleanupCompleted = false;
      var baselineRestored = false;
      var scannerCallbackCompleted = false;
      var autosaveCompleted = false;
      var nativeDatabaseReopened = false;
      var queuedVisible = false;
      var attentionVisible = false;
      var serverAttachmentVerified = false;
      var serverLifecycleVerified = false;
      var stagedAttachmentHash = '';
      final databaseCorruptionQuarantined =
          checkpoint?['databaseCorruptionQuarantined'] == true;

      try {
        if (nextStage == 'seed') {
          final corruptionQuarantined = await _verifyCorruptionQuarantine();
          await _fault('reset');
          await _pumpApp(tester, store, 'm11-seed');
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
          salesProductSku = selectM11SalesFixture(inventory.items).sku;
          final barcodeSeed = await inventory.lookupBarcode(
            RimsE2eConfig.injectedBarcode,
          );
          expect(
            barcodeSeed,
            isNotNull,
            reason: 'M11 offline scanner requires an online barcode cache seed',
          );
          await tapAndSettle(tester, const Key('bottom-nav-reports'));
          final reports = await _viewModel<ReportsViewModel>(tester);
          await waitUntil(
            tester,
            description: 'online report seed',
            condition: () => !reports.isLoading,
          );
          await tapAndSettle(tester, const Key('bottom-nav-documents'));
          final documents = await _documentsViewModel(tester);
          await waitUntil(
            tester,
            description: 'online document seed',
            condition: () =>
                !documents.isLoading && documents.recentDocuments.isNotEmpty,
          );
          accountId = documents.accountId!;
          stockBefore = await _stockQuantity(documents, {
            RimsE2eConfig.fixtureProductCode,
            salesProductSku,
          });
          final cachedDetailId = documents.recentDocuments.first.id;
          await _openDocumentDetail(tester, cachedDetailId);
          await _closeDocumentDetail(tester);
          await _verifyLocalTransportFaults(tester);
          await _fault('airplane-mode', {'restoreMs': '3500'});
          await tester.pump(const Duration(milliseconds: 500));
          cacheReadLatencyMs = await _verifyCachedReads(
            tester,
            cachedDetailId: cachedDetailId,
          );
          expect(cacheReadLatencyMs, lessThanOrEqualTo(500));
          await tester.pump(const Duration(seconds: 4));
          await _fault('reset');
          await _writeCheckpoint(checkpointFile, <String, Object?>{
            'nextStage': 'offline-draft',
            'runId': runId,
            'accountId': accountId,
            'salesProductSku': salesProductSku,
            'stockBefore': stockBefore,
            'cacheReadLatencyMs': cacheReadLatencyMs,
            'databaseCorruptionQuarantined': corruptionQuarantined,
          });
          _emitStage('seed');
          return;
        }

        if (nextStage == 'offline-draft') {
          await _fault('unreachable');
          await _pumpApp(tester, store, 'm11-offline-draft');
          await waitForKey(tester, const Key('bottom-nav-home'));
          await tapAndSettle(tester, const Key('bottom-nav-documents'));
          final documents = await _documentsViewModel(tester);
          await tapAndSettle(tester, const Key('document-scan-product-button'));
          await expectText(tester, '需要相机权限才能扫描条码');
          await tester.tap(find.byKey(const Key('scanner-permission-retry')));
          await tester.pump();
          await settleBounded(tester);
          await waitUntil(
            tester,
            description: 'M11 injected scanner callback',
            condition: () => documents.draftLines.length == 1,
          );
          scannerCallbackCompleted = true;
          final autosaveWatch = Stopwatch()..start();
          await enterText(
            tester,
            const Key('document-remark-field'),
            remarks.queued,
          );
          draftSaveLatencyMs = await _waitForPersistedDraft(
            tester,
            documents,
            accountId: accountId,
            remark: remarks.queued,
          );
          autosaveWatch.stop();
          draftAutosaveEndToEndMs = _max(
            autosaveWatch.elapsedMilliseconds,
            draftAutosaveDebounceMs + draftSaveLatencyMs,
          );
          expect(
            draftAutosaveEndToEndMs,
            greaterThanOrEqualTo(draftAutosaveDebounceMs),
          );
          expect(draftSaveLatencyMs, lessThanOrEqualTo(250));
          autosaveCompleted = true;
          final draftId = documents.activeDraftId!;
          final recoveredProductId = documents.draftLines.single.productId;
          await _writeCheckpoint(checkpointFile, <String, Object?>{
            ...checkpoint!,
            'nextStage': 'recovery',
            'draftId': draftId,
            'recoveredProductId': recoveredProductId,
            'draftSaveLatencyMs': draftSaveLatencyMs,
            'draftAutosaveEndToEndMs': draftAutosaveEndToEndMs,
            'scannerCallbackCompleted': scannerCallbackCompleted,
            'autosaveCompleted': autosaveCompleted,
          });
          _emitStage('offline-draft');
          return;
        }

        expect(nextStage, 'recovery');
        final draftId = checkpoint!['draftId']!.toString();
        final recoveredProductId = (checkpoint['recoveredProductId'] as num)
            .toInt();
        scannerCallbackCompleted =
            checkpoint['scannerCallbackCompleted'] == true;
        autosaveCompleted = checkpoint['autosaveCompleted'] == true;
        await _pumpApp(tester, store, 'm11-recovery');
        await waitForKey(tester, const Key('bottom-nav-home'));
        nativeDatabaseReopened = store is OfflineDatabase;
        await tapAndSettle(tester, const Key('bottom-nav-profile'));
        await scrollUntilVisible(
          tester,
          const Key('profile-draft-manager-entry'),
        );
        await tapAndSettle(tester, const Key('profile-draft-manager-entry'));
        await expectText(tester, '草稿管理');
        final processRecoveryWatch = Stopwatch()..start();
        await tapFinderAndSettle(
          tester,
          find.byTooltip('打开').first,
          description: 'open persisted draft from draft manager',
        );
        var documents = await _documentsViewModel(tester);
        await waitForKey(
          tester,
          Key('document-draft-line-$recoveredProductId'),
          timeout: const Duration(seconds: 1),
        );
        processRecoveryWatch.stop();
        processRecoveryLatencyMs = processRecoveryWatch.elapsedMilliseconds;
        expect(processRecoveryLatencyMs, lessThanOrEqualTo(1000));
        expect(documents.activeDraftId, draftId);
        expect(documents.remark, remarks.queued);

        await _fault('unreachable');
        final beforeQueued = await _operations(outbox, accountId);
        final queuedResult = await _queueCurrentDraft(
          tester,
          documents,
          beforeQueued,
        );
        final queuedCreate = queuedResult.operation;
        outboxEnqueueLatencyMs = queuedResult.enqueueLatencyMs;
        expect(outboxEnqueueLatencyMs, lessThanOrEqualTo(250));
        _recordOperation(queuedCreate, operationIds, idempotencyHashes);
        queuedVisible = await _operationVisibleInSyncCenter(
          tester,
          queuedCreate.operationId,
        );
        expect(queuedVisible, isTrue);

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
          sku: salesProductSku,
          remark: remarks.unknown,
          withAttachment: false,
        );
        final beforeUnknown = await _operations(outbox, accountId);
        await _fault('unknown-response');
        final unknownCreate = (await _queueCurrentDraft(
          tester,
          documents,
          beforeUnknown,
        )).operation;
        expect(unknownCreate.requiresStatusProbe, isTrue);
        expect(
          (unknownCreate.payload['request'] as Map)['remark'],
          remarks.unknown,
        );
        _recordOperation(unknownCreate, operationIds, idempotencyHashes);
        final unknownStatusBefore = await _fault('status');
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
        final unknownStatusAfter = await _fault('status');
        unknownStatusProbeCount =
            (unknownStatusAfter['unknownStatusProbeCount'] as num).toInt() -
            (unknownStatusBefore['unknownStatusProbeCount'] as num).toInt();
        unknownReplayRequestCount =
            (unknownStatusAfter['unknownReplayRequestCount'] as num).toInt();
        unknownIdempotencyKeyHash =
            unknownStatusAfter['unknownIdempotencyKeyHash'].toString();
        unknownRequestFingerprintHash =
            unknownStatusAfter['unknownRequestFingerprintHash'].toString();
        unknownSameTargetReplayObserved =
            unknownStatusAfter['unknownSameTargetReplayObserved'] == true;
        final expectedUnknownKeyHash = sha256
            .convert(utf8.encode(unknownCreate.idempotencyKey))
            .toString();
        unknownResponseProbed =
            unknownStatusProbeCount > 0 &&
            unknownReplayRequestCount >= 2 &&
            unknownIdempotencyKeyHash == expectedUnknownKeyHash &&
            RegExp(r'^[0-9a-f]{64}$').hasMatch(unknownRequestFingerprintHash) &&
            unknownSameTargetReplayObserved &&
            current.operationId == unknownCreate.operationId &&
            current.idempotencyKey == unknownCreate.idempotencyKey;
        expect(unknownResponseProbed, isTrue);

        await _fault('unreachable');
        await _returnToShell(tester);
        await tapAndSettle(tester, const Key('bottom-nav-documents'));
        documents = await _documentsViewModel(tester);
        await _prepareDraft(
          tester,
          documents,
          sku: salesProductSku,
          remark: remarks.attachment,
          withAttachment: true,
        );
        stagedAttachmentHash = await _singleStagedAttachmentHash();
        final beforeAttachment = await _operations(outbox, accountId);
        final attachmentCreate = (await _queueCurrentDraft(
          tester,
          documents,
          beforeAttachment,
        )).operation;
        final attachmentGraph = await _newOperations(
          outbox,
          accountId,
          beforeAttachment,
        );
        final upload = attachmentGraph.singleWhere(
          (operation) => operation.kind == OutboxOperationKind.attachmentUpload,
        );
        expect(
          upload.payload['expectedSha256']!.toString(),
          stagedAttachmentHash,
        );
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
        expect(attachmentDocuments, hasLength(1));
        final created = attachmentDocuments.single;
        await _openDocumentDetail(tester, created.id);
        final attachments = await _viewModel<AttachmentsViewModel>(tester);
        await attachments.load();
        await waitUntil(
          tester,
          description: 'authoritative server attachment',
          condition: () => !attachments.isLoading,
        );
        attachmentCount = attachments.attachments.length;
        expect(attachmentCount, 1);
        final serverAttachment = attachments.attachments.single;
        final downloadedPath =
            (await attachments.repository.download(serverAttachment)).when(
              success: (path) => path,
              failure: (failure) => throw TestFailure(failure.message),
            );
        attachmentHash = sha256
            .convert(await File(downloadedPath).readAsBytes())
            .toString();
        serverAttachmentVerified =
            attachmentHash.toLowerCase() ==
                stagedAttachmentHash.toLowerCase() &&
            serverAttachment.fileHash.toLowerCase() ==
                stagedAttachmentHash.toLowerCase();
        expect(serverAttachmentVerified, isTrue);
        await _closeDocumentDetail(tester);
        await _prepareDraft(
          tester,
          documents,
          sku: salesProductSku,
          remark: remarks.lifecycle,
          withAttachment: false,
        );
        await scrollUntilVisible(
          tester,
          const Key('document-create-button'),
          scrollable: find.byKey(const Key('documents-scroll-view')),
        );
        await tapAndSettle(tester, const Key('document-create-button'));
        await waitUntil(
          tester,
          description: 'online lifecycle draft',
          condition: () => documents.recentDocuments.any(
            (document) => document.remark == remarks.lifecycle,
          ),
        );
        final lifecycleDraft = documents.recentDocuments.singleWhere(
          (document) => document.remark == remarks.lifecycle,
        );
        final beforeLifecycle = await _operations(outbox, accountId);
        await _openDocumentDetail(tester, lifecycleDraft.id);
        await _fault('unreachable');
        await scrollUntilVisible(
          tester,
          Key('document-complete-${lifecycleDraft.id}'),
        );
        await tapAndSettle(
          tester,
          Key('document-complete-${lifecycleDraft.id}'),
        );
        await expectText(tester, '完成单据');
        await tapFinderAndSettle(
          tester,
          find.widgetWithText(FilledButton, '确认完成'),
          description: 'confirm lifecycle action',
        );
        await expectText(tester, '保存到待同步');
        await tapFinderAndSettle(
          tester,
          find.widgetWithText(FilledButton, '确认保存'),
          description: 'queue lifecycle action',
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
          sku: salesProductSku,
          remark: remarks.conflict,
          withAttachment: false,
        );
        final beforeConflict = await _operations(outbox, accountId);
        final conflictOperation = (await _queueCurrentDraft(
          tester,
          documents,
          beforeConflict,
        )).operation;
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
        attentionVisible = await _operationVisibleInAttention(
          tester,
          conflicted.operationId,
        );
        expect(attentionVisible, isTrue);
        await tapFinderAndSettle(
          tester,
          find.byTooltip('丢弃记录').first,
          description: 'discard conflicted operation',
        );
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
          sku: salesProductSku,
          remark: remarks.replacementConflict,
          withAttachment: false,
        );
        final beforeReplacementConflict = await _operations(outbox, accountId);
        final replacementConflict = (await _queueCurrentDraft(
          tester,
          documents,
          beforeReplacementConflict,
        )).operation;
        _recordOperation(replacementConflict, operationIds, idempotencyHashes);
        await _fault('reset');
        await _fault('server-conflict');
        await _syncOperation(tester, replacementConflict.operationId);
        expect(
          (await _operation(
            outbox,
            accountId,
            replacementConflict.operationId,
          )).state,
          OutboxState.conflict,
        );
        expect(
          await _operationVisibleInAttention(
            tester,
            replacementConflict.operationId,
          ),
          isTrue,
        );
        await tapFinderAndSettle(
          tester,
          find.widgetWithText(TextButton, '解决冲突').first,
          description: 'open replacement conflict dialog',
        );
        await expectText(tester, '解决冲突');
        final replacementOperationId = 'm11-replacement-$runId';
        final replacementIdempotencyKey = 'm11-replacement-key-$runId';
        await tester.enterText(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                widget.decoration?.labelText == '新 operation ID',
          ),
          replacementOperationId,
        );
        await tester.enterText(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                widget.decoration?.labelText == '新 idempotency key',
          ),
          replacementIdempotencyKey,
        );
        await tapFinderAndSettle(
          tester,
          find.widgetWithText(FilledButton, '创建替代操作'),
          description: 'confirm conflict replacement',
        );
        final replacement = await _operation(
          outbox,
          accountId,
          replacementOperationId,
        );
        expect(replacement.replacementOf, replacementConflict.operationId);
        expect(
          replacement.idempotencyKey,
          isNot(replacementConflict.idempotencyKey),
        );
        expect(replacement.state, OutboxState.queued);
        expect(
          (await _operation(
            outbox,
            accountId,
            replacementConflict.operationId,
          )).state,
          OutboxState.conflict,
        );
        _recordOperation(replacement, operationIds, idempotencyHashes);
        conflictReplacementCreated = true;
        conflictReplacementVisible = await _operationVisibleInWaiting(
          tester,
          replacement.operationId,
        );
        expect(conflictReplacementVisible, isTrue);

        await _fault('unreachable');
        await _returnToShell(tester);
        await tapAndSettle(tester, const Key('bottom-nav-documents'));
        documents = await _documentsViewModel(tester);
        await _prepareDraft(
          tester,
          documents,
          sku: salesProductSku,
          remark: remarks.staleContext,
          withAttachment: false,
        );
        final beforeStale = await _operations(outbox, accountId);
        final staleOperation = (await _queueCurrentDraft(
          tester,
          documents,
          beforeStale,
        )).operation;
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
        attentionVisible =
            attentionVisible &&
            await _operationVisibleInAttention(
              tester,
              staleOperation.operationId,
            );
        expect(attentionVisible, isTrue);
        await _fault('reset');

        await _returnToShell(tester);
        await tapAndSettle(tester, const Key('bottom-nav-documents'));
        documents = await _documentsViewModel(tester);
        await documents.load();
        stockAfter = await _stockQuantity(documents, {
          RimsE2eConfig.fixtureProductCode,
          salesProductSku,
        });
        final successfulRemarks = <String>[
          remarks.queued,
          remarks.unknown,
          remarks.attachment,
          remarks.lifecycle,
        ];
        final successfulDocuments = successfulRemarks.map((remark) {
          return documents.recentDocuments.singleWhere(
            (document) => document.remark == remark,
          );
        }).toList();
        final unknownDocument = successfulDocuments.singleWhere(
          (document) => document.remark == remarks.unknown,
        );
        final transactionCounts = <int, int>{
          for (final document in successfulDocuments)
            document.id: documents.transactions
                .where((transaction) => transaction.docId == document.id)
                .length,
        };
        final serverDocumentCount = documents.recentDocuments
            .where((document) => document.remark == remarks.unknown)
            .length;
        final unknownTransactionCount = transactionCounts[unknownDocument.id]!;
        const expectedStockDecrease = 4;
        final observedStockDecrease = stockBefore - stockAfter;
        duplicateSingleEffect =
            serverDocumentCount == 1 &&
            unknownTransactionCount == 1 &&
            unknownDocument.remark ==
                (unknownCreate.payload['request'] as Map)['remark'];
        expect(duplicateSingleEffect, isTrue);
        expect(observedStockDecrease, expectedStockDecrease);
        serverLifecycleVerified =
            documents.recentDocuments.any(
              (document) =>
                  document.id == lifecycleDraft.id && document.status == '已完成',
            ) &&
            transactionCounts[lifecycleDraft.id] == 1;
        expect(serverLifecycleVerified, isTrue);
        final duplicateDocumentCount = successfulRemarks.fold<int>(0, (
          duplicates,
          remark,
        ) {
          final count = documents.recentDocuments
              .where((document) => document.remark == remark)
              .length;
          return duplicates + (count > 1 ? count - 1 : 0);
        });
        final duplicateInventoryTransactionCount = transactionCounts.values
            .fold<int>(0, (duplicates, count) {
              return duplicates + (count > 1 ? count - 1 : 0);
            });
        expect(serverDocumentCount, 1);
        expect(duplicateDocumentCount, 0);
        expect(transactionCounts.values, everyElement(1));
        expect(duplicateInventoryTransactionCount, 0);
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
        final stagingDirectoryEmpty = await _stagingDirectoryEmpty();
        logoutCleanupCompleted =
            cleanupSnapshot.cacheEntries == 0 &&
            cleanupSnapshot.drafts == 0 &&
            cleanupSnapshot.outboxOperations == 0 &&
            cleanupSnapshot.draftAttachmentRequestIds.isEmpty &&
            stagingDirectoryEmpty;
        expect(logoutCleanupCompleted, isTrue);
        await _fault('reset');
        baselineRestored = true;

        final evidence = <String, Object?>{
          'cacheReadLatencyMs': cacheReadLatencyMs,
          'draftSaveLatencyMs': draftSaveLatencyMs,
          'draftAutosaveDebounceMs': draftAutosaveDebounceMs,
          'draftAutosaveEndToEndMs': draftAutosaveEndToEndMs,
          'processRecoveryLatencyMs': processRecoveryLatencyMs,
          'processRecoveryBoundary': processRecoveryBoundary,
          'outboxEnqueueLatencyMs': outboxEnqueueLatencyMs,
          'syncTotalMs': syncTotalMs,
          'intentionalFaultDelayMs': 3500,
          'operationIds': operationIds,
          'idempotencyKeyHashes': idempotencyHashes,
          'unknownStatusProbeCount': unknownStatusProbeCount,
          'unknownReplayRequestCount': unknownReplayRequestCount,
          'unknownIdempotencyKeyHash': unknownIdempotencyKeyHash,
          'unknownRequestFingerprintHash': unknownRequestFingerprintHash,
          'unknownSameTargetReplayObserved': unknownSameTargetReplayObserved,
          'stockBefore': stockBefore,
          'stockAfter': stockAfter,
          'expectedStockDecrease': expectedStockDecrease,
          'observedStockDecrease': observedStockDecrease,
          'serverDocumentCount': serverDocumentCount,
          'duplicateDocumentCount': duplicateDocumentCount,
          'duplicateInventoryTransactionCount':
              duplicateInventoryTransactionCount,
          'attachmentHash': attachmentHash,
          'stagedAttachmentHash': stagedAttachmentHash,
          'attachmentCount': attachmentCount,
          'databaseBytes': databaseBytes,
          'cleanup': <String, bool>{
            'accountCacheCleared': logoutCleanupCompleted,
            'outboxCleared': cleanupSnapshot.outboxOperations == 0,
            'stagingCleared':
                cleanupSnapshot.draftAttachmentRequestIds.isEmpty &&
                stagingDirectoryEmpty,
            'stagingDirectoryEmpty': stagingDirectoryEmpty,
            'baselineRestored': baselineRestored,
          },
          'journey': <String, bool>{
            'onlineSeeded': true,
            'cachedInventoryRead': true,
            'cachedReportRead': true,
            'cachedDetailRead': true,
            'draftRecovered': true,
            'scannerCallbackCompleted': scannerCallbackCompleted,
            'autosaveCompleted': autosaveCompleted,
            'nativeDatabaseReopened': nativeDatabaseReopened,
            'queuedVisible': queuedVisible,
            'attentionVisible': attentionVisible,
            'explicitSyncConfirmed': true,
            'unknownResponseProbed': unknownResponseProbed,
            'idempotentReplaySingleEffect': duplicateSingleEffect,
            'attachmentDependencyCompleted': attachmentDependencyCompleted,
            'serverAttachmentVerified': serverAttachmentVerified,
            'serverLifecycleVerified': serverLifecycleVerified,
            'staleSessionBlocked': staleSessionBlocked,
            'stalePermissionBlocked': stalePermissionBlocked,
            'conflictVisible': conflictVisible,
            'conflictResolved': conflictResolved,
            'conflictReplacementCreated': conflictReplacementCreated,
            'conflictReplacementVisible': conflictReplacementVisible,
            'logoutCleanupCompleted': logoutCleanupCompleted,
            'databaseCorruptionQuarantined': databaseCorruptionQuarantined,
          },
        };
        await checkpointFile.delete();
        binding.reportData = evidence;
        debugPrintSynchronously(
          'RIMS_E2E_RESULT ${jsonEncode(evidence)}',
          wrapWidth: null,
        );
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

Future<File> _checkpointFile() async {
  final root = await getApplicationSupportDirectory();
  return File('${root.path}${Platform.pathSeparator}rims_m11_checkpoint.json');
}

Future<Map<String, dynamic>?> _readCheckpoint(File file) async {
  if (!await file.exists()) return null;
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('M11 checkpoint must be a JSON object.');
  }
  return decoded;
}

Future<void> _writeCheckpoint(
  File file,
  Map<String, Object?> checkpoint,
) async {
  await file.writeAsString(jsonEncode(checkpoint), flush: true);
}

void _emitStage(String stage) {
  debugPrintSynchronously(
    'RIMS_E2E_STAGE ${jsonEncode(<String, Object?>{'stage': stage, 'processId': pid, 'startedAt': DateTime.now().toUtc().toIso8601String()})}',
    wrapWidth: null,
  );
}

Future<int> _waitForPersistedDraft(
  WidgetTester tester,
  DocumentsViewModel documents, {
  required String accountId,
  required String remark,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  const debounce = Duration(milliseconds: 300);
  await tester.pump(debounce);
  final persistenceWatch = Stopwatch()..start();
  do {
    final drafts = await documents.draftRepository!.list(accountId);
    if (drafts.any((draft) => draft.payload['remark'] == remark)) {
      persistenceWatch.stop();
      return persistenceWatch.elapsedMilliseconds;
    }
    await tester.pump(const Duration(milliseconds: 10));
  } while (DateTime.now().isBefore(deadline));
  throw TestFailure('Debounced autosave did not persist the M11 draft.');
}

final class _JourneyRemarks {
  const _JourneyRemarks(this.runId);

  final String runId;
  String get queued => 'M9-E2E:M11:$runId:queued';
  String get unknown => 'M9-E2E:M11:$runId:unknown';
  String get attachment => 'M9-E2E:M11:$runId:attachment';
  String get lifecycle => 'M9-E2E:M11:$runId:lifecycle';
  String get conflict => 'M9-E2E:M11:$runId:conflict-discard';
  String get replacementConflict => 'M9-E2E:M11:$runId:conflict-replacement';
  String get staleContext => 'M9-E2E:M11:$runId:stale-context';
}

Future<Map<String, dynamic>> _fault(
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
    return result;
  } on Object catch (error) {
    if (!isExpectedNetworkFaultDisconnect(action, error)) rethrow;
    return <String, dynamic>{
      'ok': true,
      'mode': action,
      'responseInterrupted': true,
    };
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
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  await _waitForBackendRecovery(tester);
}

Future<void> _waitForBackendRecovery(WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  Object? lastError;
  while (DateTime.now().isBefore(deadline)) {
    try {
      await _probeBackendHealth();
      return;
    } on Object catch (error) {
      lastError = error;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump();
    }
  }
  throw TestFailure('Backend did not recover after network switch: $lastError');
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
  final shellFinder = find.byType(AppShellPage);
  await waitUntil(
    tester,
    description: 'restored application shell',
    condition: () => shellFinder.evaluate().isNotEmpty,
  );
  final shell = tester.widget<AppShellPage>(shellFinder.first);
  final report = await shell.sessionController.logout(
    authRepository: shell.authRepository,
    draftRetention: DraftRetentionChoice.delete,
  );
  if (report != null && !report.completed) {
    throw TestFailure(
      'Unable to normalize the restored session: '
      '${report.failures.map((failure) => failure.message).join('; ')}',
    );
  }
  await settleBounded(tester);
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
  await _closeDocumentDetail(tester);
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

Future<void> _closeDocumentDetail(WidgetTester tester) async {
  await tapAndSettle(tester, const Key('document-detail-close-button'));
}

Future<void> _prepareDraft(
  WidgetTester tester,
  DocumentsViewModel documents, {
  required String sku,
  required String remark,
  required bool withAttachment,
}) async {
  await _addProductBySku(tester, documents, sku);
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

Future<({OutboxOperation operation, int enqueueLatencyMs})> _queueCurrentDraft(
  WidgetTester tester,
  DocumentsViewModel documents,
  List<OutboxOperation> before, {
  Duration timeout = const Duration(seconds: 12),
}) async {
  await scrollUntilVisible(
    tester,
    const Key('document-create-button'),
    scrollable: find.byKey(const Key('documents-scroll-view')),
  );
  await tapAndSettle(tester, const Key('document-create-button'));
  if (find.text('保存到待同步').evaluate().isEmpty) {
    await waitForKey(tester, const Key('document-create-button'));
    await tapAndSettle(tester, const Key('document-create-button'));
  }
  await expectText(tester, '保存到待同步');
  final confirm = find.widgetWithText(FilledButton, '确认保存');
  await waitUntil(
    tester,
    description: 'confirm offline queue button',
    condition: () => confirm.hitTestable().evaluate().isNotEmpty,
  );
  final enqueueWatch = Stopwatch()..start();
  await tester.tap(confirm.hitTestable().first);
  await tester.pump();
  final deadline = DateTime.now().add(timeout);
  do {
    if (documents.formError == '已保存到待同步，请前往同步中心复核') {
      break;
    }
    await tester.pump(const Duration(milliseconds: 10));
  } while (DateTime.now().isBefore(deadline));
  enqueueWatch.stop();
  if (documents.formError != '已保存到待同步，请前往同步中心复核') {
    throw TestFailure(
      'Offline enqueue did not complete after '
      '${enqueueWatch.elapsedMilliseconds} ms: ${documents.formError}',
    );
  }

  final after = await _operations(
    documents.outboxRepository!,
    documents.accountId!,
  );
  final previousIds = before.map((operation) => operation.operationId).toSet();
  final created = after
      .where(
        (operation) =>
            !previousIds.contains(operation.operationId) &&
            operation.kind == OutboxOperationKind.documentCreate,
      )
      .toList(growable: false);
  if (created.length != 1) {
    throw TestFailure(
      'Expected one new document create operation after '
      '${enqueueWatch.elapsedMilliseconds} ms, found ${created.length}.',
    );
  }
  final operation = created.single;
  await settleBounded(tester);
  return (
    operation: operation,
    enqueueLatencyMs: enqueueWatch.elapsedMilliseconds,
  );
}

Future<void> _syncOperation(WidgetTester tester, String operationId) async {
  final viewModel = await _waitForOperationInSyncCenter(tester, operationId);
  await tapFinderAndSettle(
    tester,
    find.text('复核并同步').first,
    description: 'review operation $operationId',
  );
  await expectText(tester, '复核并同步');
  await tapFinderAndSettle(
    tester,
    find.widgetWithText(FilledButton, '确认同步'),
    description: 'confirm explicit sync $operationId',
  );
  await waitUntil(
    tester,
    description: 'sync command completed',
    condition: () => !viewModel.isBusy,
    timeout: const Duration(seconds: 12),
  );
}

Future<void> _openSyncCenter(WidgetTester tester) async {
  if (find.byType(SyncCenterPage).evaluate().isNotEmpty) return;
  await _returnToShell(tester);
  await tapAndSettle(tester, const Key('bottom-nav-profile'));
  await scrollUntilVisible(tester, const Key('profile-sync-center-entry'));
  await tapAndSettle(tester, const Key('profile-sync-center-entry'));
  await waitUntil(
    tester,
    description: 'Sync Center page',
    condition: () => find.byType(SyncCenterPage).evaluate().isNotEmpty,
  );
}

Future<bool> _operationVisibleInSyncCenter(
  WidgetTester tester,
  String operationId,
) async {
  await _waitForOperationInSyncCenter(tester, operationId);
  return find.textContaining(operationId).evaluate().isNotEmpty &&
      find.text('复核并同步').evaluate().isNotEmpty;
}

Future<SyncCenterViewModel> _waitForOperationInSyncCenter(
  WidgetTester tester,
  String operationId,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 12));
  do {
    if (find.byType(SyncCenterPage).evaluate().isEmpty) {
      await _openSyncCenter(tester);
    }
    final viewModelFinder = find.byWidgetPredicate(
      (widget) =>
          widget is AnimatedBuilder && widget.animation is SyncCenterViewModel,
    );
    if (viewModelFinder.evaluate().isNotEmpty) {
      final viewModel =
          tester.widget<AnimatedBuilder>(viewModelFinder.first).animation
              as SyncCenterViewModel;
      if (!viewModel.isLoading &&
          find.textContaining(operationId).evaluate().isNotEmpty) {
        return viewModel;
      }
    }
    await tester.pump(const Duration(milliseconds: 100));
  } while (DateTime.now().isBefore(deadline));
  throw TestFailure('Timed out recovering Sync Center operation $operationId.');
}

Future<bool> _operationVisibleInAttention(
  WidgetTester tester,
  String operationId,
) async {
  await _openSyncCenter(tester);
  await tapFinderAndSettle(
    tester,
    find.textContaining('需处理').first,
    description: 'open Sync Center attention tab',
  );
  await waitUntil(
    tester,
    description: 'attention operation visible',
    condition: () => find.textContaining(operationId).evaluate().isNotEmpty,
  );
  return find.textContaining(operationId).evaluate().isNotEmpty;
}

Future<bool> _operationVisibleInWaiting(
  WidgetTester tester,
  String operationId,
) async {
  await _openSyncCenter(tester);
  await tapFinderAndSettle(
    tester,
    find.textContaining('等待').first,
    description: 'open Sync Center waiting tab',
  );
  await waitUntil(
    tester,
    description: 'replacement operation visible in waiting tab',
    condition: () => find.textContaining(operationId).evaluate().isNotEmpty,
  );
  return find.textContaining(operationId).evaluate().isNotEmpty &&
      find.text('复核并同步').evaluate().isNotEmpty;
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

Future<int> _stockQuantity(
  DocumentsViewModel documents,
  Set<String> skus,
) async {
  var total = 0;
  for (final sku in skus) {
    final result = await documents.inventoryRepository!.listInventory(
      keyword: sku,
    );
    total += result.when(
      success: (page) =>
          page.items.singleWhere((item) => item.sku == sku).stockQuantity,
      failure: (failure) => throw TestFailure(failure.message),
    );
  }
  return total;
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

Future<String> _singleStagedAttachmentHash() async {
  final root = await getApplicationSupportDirectory();
  final stagingRoot = Directory(
    '${root.path}${Platform.pathSeparator}rims_attachments',
  );
  final files = <File>[];
  if (await stagingRoot.exists()) {
    await for (final entity in stagingRoot.list(recursive: true)) {
      if (entity is File &&
          !entity.path.contains('thumbnails') &&
          !entity.path.endsWith('manifest.json')) {
        files.add(entity);
      }
    }
  }
  expect(files, hasLength(1), reason: 'one physical staged attachment');
  return sha256.convert(await files.single.readAsBytes()).toString();
}

Future<bool> _stagingDirectoryEmpty() async {
  final root = await getApplicationSupportDirectory();
  final stagingRoot = Directory(
    '${root.path}${Platform.pathSeparator}rims_attachments',
  );
  if (!await stagingRoot.exists()) return true;
  await for (final entity in stagingRoot.list(recursive: true)) {
    if (entity is File) return false;
  }
  return true;
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
