import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/inventory/domain/entities/inventory_item.dart';
import 'package:rims_frontend/features/offline/data/database/offline_database.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/offline/data/services/offline_scan_ownership_adapter.dart';
import 'package:rims_frontend/features/offline/data/services/outbox_review_invalidator.dart';
import 'package:rims_frontend/features/offline/domain/entities/cache_snapshot.dart';
import 'package:rims_frontend/features/offline/domain/entities/document_draft.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_store.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_ownership_service.dart';
import 'package:rims_frontend/features/scanner/domain/entities/scan_data.dart';
import 'package:rims_frontend/features/scanner/domain/services/scan_lookup_cache.dart';
import 'package:rims_frontend/features/scanner/domain/services/scan_session_store.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  group('OfflineOwnershipService', () {
    test('logout clears owned data and deletes drafts by default', () async {
      final fixture = _Fixture();

      final report = await fixture.service.apply(
        const OfflineOwnershipIntent.logout(accountId: '7'),
      );

      expect(report.completed, isTrue);
      expect(fixture.store.clearAccountCalls, [('7', false)]);
      expect(fixture.files.clearAccountCalls.single.$1, '7');
      expect(fixture.files.clearAccountCalls.single.$2, isEmpty);
      expect(fixture.scans.clearedAccounts, ['7']);
      expect(fixture.scans.clearedLookupAccounts, ['7']);
      expect(fixture.service.canSync('7'), isFalse);
    });

    test(
      'logout retains drafts and exactly their staged attachments only after '
      'explicit local retention choice',
      () async {
        final fixture = _Fixture(
          store: _FakeOwnershipStore(
            snapshots: {
              '7': const OfflineStoreOwnershipSnapshot(
                cacheEntries: 2,
                drafts: 1,
                outboxOperations: 3,
                draftAttachmentRequestIds: {'draft-file'},
              ),
            },
          ),
        );

        final report = await fixture.service.apply(
          const OfflineOwnershipIntent.logout(
            accountId: '7',
            draftRetention: DraftRetentionChoice.retainLocally,
          ),
        );

        expect(report.completed, isTrue);
        expect(fixture.store.clearAccountCalls, [('7', true)]);
        expect(fixture.files.clearAccountCalls.single.$1, '7');
        expect(fixture.files.clearAccountCalls.single.$2, {'draft-file'});
      },
    );

    test(
      'retained draft attachment enumeration failure aborts every destructive cleanup',
      () async {
        final store = _FakeOwnershipStore(
          snapshots: {
            '7': const OfflineStoreOwnershipSnapshot(
              drafts: 1,
              draftAttachmentRequestIds: {'draft-file'},
            ),
          },
          failOnInspectCall: 2,
        );
        final fixture = _Fixture(store: store);

        final report = await fixture.service.apply(
          const OfflineOwnershipIntent.logout(
            accountId: '7',
            draftRetention: DraftRetentionChoice.retainLocally,
          ),
        );

        expect(report.completed, isFalse);
        expect(store.clearAccountCalls, isEmpty);
        expect(fixture.files.clearAccountCalls, isEmpty);
        expect(fixture.scans.clearedAccounts, isEmpty);
      },
    );

    test(
      'token expiry preserves all data and blocks sync until same account reauthenticates',
      () async {
        final fixture = _Fixture();

        final expired = await fixture.service.apply(
          const OfflineOwnershipIntent.tokenExpiry(accountId: '7'),
        );

        expect(expired.completed, isTrue);
        expect(fixture.store.clearAccountCalls, isEmpty);
        expect(fixture.files.clearAccountCalls, isEmpty);
        expect(fixture.reviews.calls, [('7', null)]);
        expect(fixture.service.canSync('7'), isFalse);

        await fixture.service.apply(
          const OfflineOwnershipIntent.reauthenticated(accountId: '7'),
        );
        expect(fixture.service.canSync('7'), isTrue);
        expect(fixture.service.canSync('8'), isTrue);
      },
    );

    test(
      'account switch clears only the previous account before allowing the next account',
      () async {
        final fixture = _Fixture();

        final report = await fixture.service.apply(
          const OfflineOwnershipIntent.accountSwitch(
            previousAccountId: '7',
            currentAccountId: '8',
          ),
        );

        expect(report.completed, isTrue);
        expect(fixture.store.clearAccountCalls, [('7', false)]);
        expect(fixture.scans.clearedAccounts, ['7']);
        expect(fixture.scans.clearedLookupAccounts, ['7']);
        expect(
          fixture.store.clearAccountCalls.where((call) => call.$1 == '8'),
          isEmpty,
        );
        expect(fixture.service.canAccessOfflineData('8'), isTrue);
      },
    );

    test(
      'warehouse switch invalidates only the old warehouse cache and reviews',
      () async {
        final fixture = _Fixture();
        final blocker = Completer<void>();
        fixture.reviews.blocker = blocker.future;

        final pending = fixture.service.apply(
          const OfflineOwnershipIntent.warehouseSwitch(
            accountId: '7',
            previousWarehouseId: 11,
            currentWarehouseId: 12,
          ),
        );
        await fixture.reviews.started.future;

        expect(fixture.service.canSync('7'), isFalse);
        blocker.complete();
        final report = await pending;

        expect(report.completed, isTrue);
        expect(fixture.service.canSync('7'), isTrue);
        expect(fixture.store.invalidatedWarehouses, [('7', 11)]);
        expect(fixture.reviews.calls, [('7', 11)]);
        expect(fixture.scans.clearedLookupWarehouses, [('7', 11)]);
        expect(fixture.scans.clearedAccounts, isEmpty);
        expect(fixture.store.clearAccountCalls, isEmpty);
      },
    );

    test(
      'role or permission refresh invalidates cache and reviewed sync authority without deleting work',
      () async {
        final fixture = _Fixture();

        final report = await fixture.service.apply(
          const OfflineOwnershipIntent.permissionRefresh(accountId: '7'),
        );

        expect(report.completed, isTrue);
        expect(fixture.store.permissionInvalidations, ['7']);
        expect(fixture.reviews.calls, [('7', null)]);
        expect(fixture.scans.clearedLookupAccounts, ['7']);
        expect(fixture.scans.clearedAccounts, isEmpty);
        expect(fixture.store.clearAccountCalls, isEmpty);
        expect(fixture.files.clearAccountCalls, isEmpty);
      },
    );

    test(
      'failed permission invalidation stays blocked across reauthentication',
      () async {
        final fixture = _Fixture();
        fixture.reviews.fails = true;

        final failed = await fixture.service.apply(
          const OfflineOwnershipIntent.permissionRefresh(accountId: '7'),
        );
        expect(failed.completed, isFalse);
        expect(fixture.service.canSync('7'), isFalse);

        await fixture.service.apply(
          const OfflineOwnershipIntent.reauthenticated(accountId: '7'),
        );
        expect(fixture.service.canSync('7'), isFalse);

        fixture.reviews.fails = false;
        final retried = await fixture.service.apply(
          const OfflineOwnershipIntent.permissionRefresh(accountId: '7'),
        );
        expect(retried.completed, isTrue);
        expect(fixture.service.canSync('7'), isTrue);
      },
    );

    test(
      'invalid cached session removes only that projection through the ownership boundary',
      () async {
        final fixture = _Fixture();

        final report = await fixture.service.apply(
          const OfflineOwnershipIntent.invalidSessionProjection(accountId: '7'),
        );

        expect(report.completed, isTrue);
        expect(fixture.store.discardedSessionProjections, ['7']);
        expect(fixture.store.clearAccountCalls, isEmpty);
        expect(fixture.service.canSync('7'), isFalse);
      },
    );

    test(
      'full revocation clears all sensitive data before rotating the database key',
      () async {
        final fixture = _Fixture();

        final report = await fixture.service.apply(
          const OfflineOwnershipIntent.revocation(accountId: '7'),
        );

        expect(report.completed, isTrue);
        expect(fixture.order, [
          'store.clearAll',
          'files.clearAll',
          'scans.clearAllSessions',
          'scans.clearAllLookups',
          'keys.rotate',
        ]);
        expect(fixture.service.canAccessOfflineData('7'), isFalse);
      },
    );

    test(
      'database key rotation failure is visible and revocation never reports success',
      () async {
        final fixture = _Fixture(keyRotationFails: true);

        final report = await fixture.service.apply(
          const OfflineOwnershipIntent.revocation(accountId: '7'),
        );

        expect(report.completed, isFalse);
        expect(
          report.failures.map((failure) => failure.step),
          contains(OfflineOwnershipStep.databaseKey),
        );
        expect(fixture.service.canAccessOfflineData('7'), isFalse);
      },
    );

    test(
      'clear-cache count change requires confirmation of the current exact snapshot before deletion',
      () async {
        final store = _FakeOwnershipStore(
          snapshots: {
            '7': const OfflineStoreOwnershipSnapshot(
              cacheEntries: 4,
              drafts: 2,
              outboxOperations: 3,
            ),
          },
        );
        final files = _FakeOwnedFiles(
          snapshots: {
            '7': const OfflineFileOwnershipSnapshot(
              stagedTransfers: 5,
              downloads: 6,
            ),
          },
        );
        final scans = _FakeOwnedScans(counts: {'7': 7});
        final fixture = _Fixture(store: store, files: files, scans: scans);

        final preview = await fixture.service.preview(
          accountId: '7',
          command: OfflineClearCommand.cache,
        );
        expect(
          preview.counts,
          const OfflineOwnershipCounts(
            cacheEntries: 4,
            drafts: 2,
            outboxOperations: 3,
            stagedTransfers: 5,
            downloads: 6,
            scanSessions: 7,
          ),
        );

        store.snapshots['7'] = const OfflineStoreOwnershipSnapshot(
          cacheEntries: 5,
          drafts: 2,
          outboxOperations: 3,
        );
        final report = await fixture.service.executeClear(preview);

        expect(report.completed, isFalse);
        expect(report.requiresReconfirmation, isTrue);
        expect(report.executedCounts.cacheEntries, 5);
        expect(report.currentPreview?.counts.cacheEntries, 5);
        expect(store.clearCacheCalls, isEmpty);
        expect(files.clearedDownloads, isEmpty);
        expect(store.clearOfflineWorkCalls, isEmpty);

        final confirmed = await fixture.service.executeClear(
          report.currentPreview!,
        );
        expect(confirmed.completed, isTrue);
        expect(store.clearCacheCalls, ['7']);
        expect(files.clearedDownloads, ['7']);
        expect(scans.clearedLookupAccounts, ['7']);
        expect(scans.clearedAccounts, isEmpty);
      },
    );

    test(
      'clear-offline-work has explicit scope and leaves cache and downloads untouched',
      () async {
        final fixture = _Fixture();
        final preview = await fixture.service.preview(
          accountId: '7',
          command: OfflineClearCommand.offlineWork,
        );

        final report = await fixture.service.executeClear(preview);

        expect(report.completed, isTrue);
        expect(fixture.store.clearOfflineWorkCalls, ['7']);
        expect(fixture.files.clearedStagedTransfers, ['7']);
        expect(fixture.scans.clearedAccounts, ['7']);
        expect(fixture.scans.clearedLookupAccounts, isEmpty);
        expect(fixture.store.clearCacheCalls, isEmpty);
        expect(fixture.files.clearedDownloads, isEmpty);
      },
    );

    test('equal-count cache replacement requires reconfirmation', () async {
      final store = _FakeOwnershipStore(
        snapshots: {
          '7': const OfflineStoreOwnershipSnapshot(
            cacheEntries: 1,
            contentIdentities: {'cache:old:1'},
          ),
        },
      );
      final fixture = _Fixture(store: store);
      final preview = await fixture.service.preview(
        accountId: '7',
        command: OfflineClearCommand.cache,
      );
      store.snapshots['7'] = const OfflineStoreOwnershipSnapshot(
        cacheEntries: 1,
        contentIdentities: {'cache:new:1'},
      );

      final changed = await fixture.service.executeClear(preview);

      expect(changed.requiresReconfirmation, isTrue);
      expect(store.clearCacheCalls, isEmpty);
      expect(fixture.files.clearedDownloads, isEmpty);
    });

    test('clear-cache ignores offline-work-only snapshot changes', () async {
      final store = _FakeOwnershipStore(
        snapshots: {
          '7': const OfflineStoreOwnershipSnapshot(
            cacheEntries: 1,
            drafts: 1,
            outboxOperations: 1,
            contentIdentities: {'cache:stable', 'draft:old', 'outbox:old'},
          ),
        },
      );
      final fixture = _Fixture(store: store);
      final preview = await fixture.service.preview(
        accountId: '7',
        command: OfflineClearCommand.cache,
      );
      store.snapshots['7'] = const OfflineStoreOwnershipSnapshot(
        cacheEntries: 1,
        drafts: 2,
        outboxOperations: 2,
        contentIdentities: {'cache:stable', 'draft:new', 'outbox:new'},
      );

      final report = await fixture.service.executeClear(preview);

      expect(report.completed, isTrue);
      expect(store.clearCacheCalls, ['7']);
    });

    test('clear-offline-work ignores cache-only snapshot changes', () async {
      final store = _FakeOwnershipStore(
        snapshots: {
          '7': const OfflineStoreOwnershipSnapshot(
            cacheEntries: 1,
            drafts: 1,
            contentIdentities: {'cache:old', 'draft:stable'},
          ),
        },
      );
      final fixture = _Fixture(store: store);
      final preview = await fixture.service.preview(
        accountId: '7',
        command: OfflineClearCommand.offlineWork,
      );
      store.snapshots['7'] = const OfflineStoreOwnershipSnapshot(
        cacheEntries: 2,
        drafts: 1,
        contentIdentities: {'cache:new', 'draft:stable'},
      );

      final report = await fixture.service.executeClear(preview);

      expect(report.completed, isTrue);
      expect(store.clearOfflineWorkCalls, ['7']);
    });

    test(
      'equal-count offline-work replacement requires reconfirmation',
      () async {
        final store = _FakeOwnershipStore(
          snapshots: {
            '7': const OfflineStoreOwnershipSnapshot(
              drafts: 1,
              contentIdentities: {'draft:old'},
            ),
          },
        );
        final fixture = _Fixture(store: store);
        final preview = await fixture.service.preview(
          accountId: '7',
          command: OfflineClearCommand.offlineWork,
        );
        store.snapshots['7'] = const OfflineStoreOwnershipSnapshot(
          drafts: 1,
          contentIdentities: {'draft:new'},
        );

        final report = await fixture.service.executeClear(preview);

        expect(report.requiresReconfirmation, isTrue);
        expect(store.clearOfflineWorkCalls, isEmpty);
      },
    );

    test('ownership mutations are serialized', () async {
      final blocker = Completer<void>();
      final store = _FakeOwnershipStore(clearBlocker: blocker.future);
      final fixture = _Fixture(store: store);

      final first = fixture.service.apply(
        const OfflineOwnershipIntent.logout(accountId: '7'),
      );
      await store.clearStarted.future;
      final second = fixture.service.apply(
        const OfflineOwnershipIntent.accountSwitch(
          previousAccountId: '8',
          currentAccountId: '9',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(store.clearAccountCalls, [('7', false)]);
      blocker.complete();
      await Future.wait([first, second]);
      expect(store.clearAccountCalls, [('7', false), ('8', false)]);
    });

    test(
      'mutation quiescence timeout fails closed instead of hanging',
      () async {
        final participant = _BlockingMutationParticipant();
        final fixture = _Fixture(
          participant: participant,
          mutationQuiescenceTimeout: const Duration(milliseconds: 10),
        );

        final report = await fixture.service.apply(
          const OfflineOwnershipIntent.logout(accountId: '7'),
        );

        expect(report.completed, isFalse);
        expect(
          report.failures,
          contains(
            isA<OfflineOwnershipFailure>().having(
              (failure) => failure.step,
              'step',
              OfflineOwnershipStep.mutationQuiescence,
            ),
          ),
        );
        expect(fixture.store.clearAccountCalls, isEmpty);
        expect(fixture.service.canSync('7'), isFalse);
      },
    );

    test(
      'logout account switch and permission refresh drain active mutations before cleanup',
      () async {
        final intents = <OfflineOwnershipIntent>[
          const OfflineOwnershipIntent.logout(accountId: '7'),
          const OfflineOwnershipIntent.accountSwitch(
            previousAccountId: '7',
            currentAccountId: '8',
          ),
          const OfflineOwnershipIntent.permissionRefresh(accountId: '7'),
        ];

        for (final intent in intents) {
          final participant = _BlockingMutationParticipant();
          final fixture = _Fixture(participant: participant);

          final pending = fixture.service.apply(intent);
          await participant.started.future;

          expect(fixture.service.canSync(intent.accountId), isFalse);
          expect(fixture.store.clearAccountCalls, isEmpty);
          expect(fixture.store.permissionInvalidations, isEmpty);
          expect(fixture.files.clearAccountCalls, isEmpty);
          expect(fixture.scans.clearedAccounts, isEmpty);

          participant.release.complete();
          final report = await pending;
          expect(report.completed, isTrue);
        }
      },
    );
  });

  group('ownership storage contract', () {
    test(
      'Memory store reports exact counts and clears categories independently',
      () async {
        final store = MemoryOfflineStore();
        await _exerciseOwnershipStore(store, store);
      },
    );

    test(
      'Drift store reports exact counts and clears categories atomically',
      () async {
        final store = OfflineDatabase.forTesting(NativeDatabase.memory());
        addTearDown(store.close);
        await _exerciseOwnershipStore(store, store);
      },
    );

    test('Memory cache revision is canonical and payload-sensitive', () async {
      final store = MemoryOfflineStore();
      await _expectCanonicalCacheRevision(store, store);
    });

    test('Drift cache revision is canonical and payload-sensitive', () async {
      final store = OfflineDatabase.forTesting(NativeDatabase.memory());
      addTearDown(store.close);
      await _expectCanonicalCacheRevision(store, store);
    });
  });

  for (final useDrift in [false, true]) {
    final storeName = useDrift ? 'Drift' : 'Memory';

    test(
      '$storeName clear-offline-work preserves current and legacy lookup cache',
      () async {
        final fixture = await _RealScanOwnershipFixture.create(
          useDrift: useDrift,
        );
        await fixture.seed();
        final preview = await fixture.service.preview(
          accountId: '7',
          command: OfflineClearCommand.offlineWork,
        );
        expect(preview.counts.cacheEntries, 3);
        expect(preview.counts.scanSessions, 1);
        await fixture.lookupCache.put(
          userId: '7',
          warehouseId: 11,
          barcode: 'CURRENT',
          item: _scanItem(productId: 2),
        );

        final report = await fixture.service.executeClear(preview);

        expect(report.completed, isTrue);
        expect(report.requiresReconfirmation, isFalse);
        expect(
          await fixture.sessions.restore(userId: '7', warehouseId: 11),
          isNull,
        );
        expect(
          (await fixture.lookupCache.get(
            userId: '7',
            warehouseId: 11,
            barcode: 'CURRENT',
          ))?.identity.productId,
          2,
        );
        expect(
          await fixture.legacyLookupCache.get(
            userId: '7',
            warehouseId: 12,
            barcode: 'LEGACY',
          ),
          isNotNull,
        );
        expect(
          await fixture.store.readCache(
            const CacheKey(
              accountId: '7',
              warehouseId: 11,
              namespace: 'inventory',
              entityKey: 'page-1',
            ),
          ),
          isNotNull,
        );
        expect(fixture.files.clearedDownloads, isEmpty);
        final remaining = await fixture.ownershipStore.inspectAccount('7');
        expect(remaining.drafts, 0);
        expect(remaining.outboxOperations, 0);
      },
    );

    test(
      '$storeName clear-cache tracks lookup revision and preserves offline work',
      () async {
        final fixture = await _RealScanOwnershipFixture.create(
          useDrift: useDrift,
        );
        await fixture.seed();
        final preview = await fixture.service.preview(
          accountId: '7',
          command: OfflineClearCommand.cache,
        );
        expect(preview.counts.cacheEntries, 3);
        expect(preview.counts.scanSessions, 1);
        await fixture.lookupCache.put(
          userId: '7',
          warehouseId: 11,
          barcode: 'CURRENT',
          item: _scanItem(productId: 2),
        );

        final changed = await fixture.service.executeClear(preview);

        expect(changed.requiresReconfirmation, isTrue);
        expect(
          await fixture.lookupCache.get(
            userId: '7',
            warehouseId: 11,
            barcode: 'CURRENT',
          ),
          isNotNull,
        );
        await fixture.sessions.save(
          userId: '7',
          warehouseId: 11,
          session: ScanSessionSnapshot(
            mode: ScanMode.batch,
            lines: [ScanLine(item: _scanItem(productId: 3), quantity: 2)],
          ),
        );

        final confirmed = await fixture.service.executeClear(
          changed.currentPreview!,
        );

        expect(confirmed.completed, isTrue);
        expect(confirmed.requiresReconfirmation, isFalse);
        expect(
          await fixture.lookupCache.get(
            userId: '7',
            warehouseId: 11,
            barcode: 'CURRENT',
          ),
          isNull,
        );
        expect(
          await fixture.legacyLookupCache.get(
            userId: '7',
            warehouseId: 12,
            barcode: 'LEGACY',
          ),
          isNull,
        );
        expect(
          await fixture.sessions.restore(userId: '7', warehouseId: 11),
          isNotNull,
        );
        final remaining = await fixture.ownershipStore.inspectAccount('7');
        expect(remaining.drafts, 1);
        expect(remaining.outboxOperations, 1);
        expect(fixture.files.clearedStagedTransfers, isEmpty);
        expect(fixture.files.clearedDownloads, ['7']);
      },
    );

    test(
      '$storeName destructive ownership clears scan sessions and lookup caches',
      () async {
        final intents = <OfflineOwnershipIntent>[
          const OfflineOwnershipIntent.logout(accountId: '7'),
          const OfflineOwnershipIntent.accountSwitch(
            previousAccountId: '7',
            currentAccountId: '8',
          ),
          const OfflineOwnershipIntent.revocation(accountId: '7'),
        ];
        for (final intent in intents) {
          final fixture = await _RealScanOwnershipFixture.create(
            useDrift: useDrift,
          );
          await fixture.seed();

          final report = await fixture.service.apply(intent);

          expect(report.completed, isTrue, reason: intent.reason.name);
          expect(
            await fixture.sessions.restore(userId: '7', warehouseId: 11),
            isNull,
            reason: intent.reason.name,
          );
          expect(
            await fixture.lookupCache.get(
              userId: '7',
              warehouseId: 11,
              barcode: 'CURRENT',
            ),
            isNull,
            reason: intent.reason.name,
          );
          expect(
            await fixture.legacyLookupCache.get(
              userId: '7',
              warehouseId: 12,
              barcode: 'LEGACY',
            ),
            isNull,
            reason: intent.reason.name,
          );
          await fixture.dispose();
        }
      },
    );

    test(
      '$storeName warehouse and permission invalidation preserve scan sessions',
      () async {
        final fixture = await _RealScanOwnershipFixture.create(
          useDrift: useDrift,
        );
        await fixture.seed();

        final warehouse = await fixture.service.apply(
          const OfflineOwnershipIntent.warehouseSwitch(
            accountId: '7',
            previousWarehouseId: 11,
            currentWarehouseId: 13,
          ),
        );

        expect(warehouse.completed, isTrue);
        expect(
          await fixture.sessions.restore(userId: '7', warehouseId: 11),
          isNotNull,
        );
        expect(
          await fixture.lookupCache.get(
            userId: '7',
            warehouseId: 11,
            barcode: 'CURRENT',
          ),
          isNull,
        );
        expect(
          await fixture.legacyLookupCache.get(
            userId: '7',
            warehouseId: 12,
            barcode: 'LEGACY',
          ),
          isNotNull,
        );

        final permission = await fixture.service.apply(
          const OfflineOwnershipIntent.permissionRefresh(accountId: '7'),
        );

        expect(permission.completed, isTrue);
        expect(
          await fixture.sessions.restore(userId: '7', warehouseId: 11),
          isNotNull,
        );
        expect(
          await fixture.legacyLookupCache.get(
            userId: '7',
            warehouseId: 12,
            barcode: 'LEGACY',
          ),
          isNull,
        );
      },
    );
  }

  test('review invalidation is account and warehouse scoped', () async {
    final store = MemoryOfflineStore();
    final now = DateTime.utc(2026, 7, 13, 12);
    for (final warehouseId in [11, 12]) {
      await store.outboxRepository.enqueue(
        OutboxOperation(
          operationId: 'operation-$warehouseId',
          idempotencyKey: 'key-$warehouseId',
          accountId: '7',
          warehouseId: warehouseId,
          kind: OutboxOperationKind.documentCreate,
          payload: const {},
          state: OutboxState.queued,
          createdAt: now,
          confirmedAt: now,
          reviewStamp: 'review-$warehouseId',
        ),
      );
    }

    await OutboxReviewInvalidator(
      repository: store.outboxRepository,
    ).invalidate(accountId: '7', warehouseId: 11);

    final operations = await store.outboxRepository.list('7');
    final listed = operations.when(
      success: (value) => value,
      failure: (failure) => throw TestFailure(failure.message),
    );
    final oldWarehouse = listed.singleWhere(
      (operation) => operation.warehouseId == 11,
    );
    final currentWarehouse = listed.singleWhere(
      (operation) => operation.warehouseId == 12,
    );
    expect(oldWarehouse.confirmedAt, isNull);
    expect(oldWarehouse.reviewStamp, isNull);
    expect(currentWarehouse.confirmedAt, now);
    expect(currentWarehouse.reviewStamp, 'review-12');
  });
}

final class _RealScanOwnershipFixture {
  _RealScanOwnershipFixture._({
    required this.store,
    required this.ownershipStore,
    required this.sessions,
    required this.lookupCache,
    required this.legacyLookupCache,
    required this.files,
    required this.service,
    required this._previousPreferencesPlatform,
    required this._preferencesPlatform,
    this._database,
  });

  static Future<_RealScanOwnershipFixture> create({
    required bool useDrift,
  }) async {
    final previousPlatform = SharedPreferencesAsyncPlatform.instance;
    final preferencesPlatform = InMemorySharedPreferencesAsync.empty();
    SharedPreferencesAsyncPlatform.instance = preferencesPlatform;

    late final OfflineStore store;
    late final OfflineOwnershipStore ownershipStore;
    OfflineDatabase? database;
    if (useDrift) {
      database = OfflineDatabase.forTesting(NativeDatabase.memory());
      store = database;
      ownershipStore = database;
    } else {
      final memory = MemoryOfflineStore();
      store = memory;
      ownershipStore = memory;
    }
    final legacyStorage = SharedPreferencesAsyncScanStorage();
    final sessions = ScanSessionStore(storage: legacyStorage);
    final lookupCache = ScanLookupCache(
      storage: legacyStorage,
      offlineStore: store,
    );
    final legacyLookupCache = ScanLookupCache(storage: legacyStorage);
    final scans = OfflineScanOwnershipAdapter(
      sessions: sessions,
      lookupCache: lookupCache,
    );
    final files = _FakeOwnedFiles(
      snapshots: {
        '7': const OfflineFileOwnershipSnapshot(
          stagedTransfers: 1,
          downloads: 1,
        ),
      },
    );
    final order = <String>[];
    final service = OfflineOwnershipService(
      store: ownershipStore,
      files: files,
      scans: scans,
      reviews: _FakeReviews(),
      databaseKeys: _FakeKeys(order: order, fails: false),
    );
    final fixture = _RealScanOwnershipFixture._(
      store: store,
      ownershipStore: ownershipStore,
      sessions: sessions,
      lookupCache: lookupCache,
      legacyLookupCache: legacyLookupCache,
      files: files,
      service: service,
      previousPreferencesPlatform: previousPlatform,
      preferencesPlatform: preferencesPlatform,
      database: database,
    );
    addTearDown(fixture.dispose);
    return fixture;
  }

  final OfflineStore store;
  final OfflineOwnershipStore ownershipStore;
  final ScanSessionStore sessions;
  final ScanLookupCache lookupCache;
  final ScanLookupCache legacyLookupCache;
  final _FakeOwnedFiles files;
  final OfflineOwnershipService service;
  final SharedPreferencesAsyncPlatform? _previousPreferencesPlatform;
  final SharedPreferencesAsyncPlatform _preferencesPlatform;
  final OfflineDatabase? _database;
  bool _disposed = false;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _database?.close();
    if (identical(
      SharedPreferencesAsyncPlatform.instance,
      _preferencesPlatform,
    )) {
      SharedPreferencesAsyncPlatform.instance = _previousPreferencesPlatform;
    }
  }

  Future<void> seed() async {
    final now = DateTime.utc(2026, 7, 14, 9);
    await store.writeCache(
      CacheRecord(
        key: const CacheKey(
          accountId: '7',
          warehouseId: 11,
          namespace: 'inventory',
          entityKey: 'page-1',
        ),
        payload: const {'value': 1},
        schemaVersion: 1,
        fetchedAt: now,
        expiresAt: now.add(const Duration(days: 1)),
      ),
    );
    await lookupCache.put(
      userId: '7',
      warehouseId: 11,
      barcode: 'CURRENT',
      item: _scanItem(productId: 1),
    );
    await legacyLookupCache.put(
      userId: '7',
      warehouseId: 12,
      barcode: 'LEGACY',
      item: _scanItem(productId: 12),
    );
    await sessions.save(
      userId: '7',
      warehouseId: 11,
      session: ScanSessionSnapshot(
        mode: ScanMode.batch,
        lines: [ScanLine(item: _scanItem(productId: 1), quantity: 1)],
      ),
    );
    await store.saveDraft(
      DocumentDraft(
        id: 'draft-7',
        accountId: '7',
        warehouseId: 11,
        payload: const {},
        createdAt: now,
        updatedAt: now,
      ),
    );
    await store.enqueue(
      OutboxOperation(
        operationId: 'operation-7',
        idempotencyKey: 'key-7',
        accountId: '7',
        warehouseId: 11,
        kind: OutboxOperationKind.documentCreate,
        payload: const {},
        state: OutboxState.queued,
        createdAt: now,
      ),
      const {},
    );
  }
}

InventoryItem _scanItem({required int productId}) => InventoryItem(
  id: productId + 1000,
  productId: productId,
  productName: 'Product $productId',
  sku: 'SKU-$productId',
  availableQuantity: 5,
  stockQuantity: 6,
  statusLabel: 'Enabled',
  imageUrl: '/products/$productId.png',
);

Future<void> _exerciseOwnershipStore(
  OfflineStore store,
  OfflineOwnershipStore ownership,
) async {
  final now = DateTime.utc(2026, 7, 13, 12);
  await store.writeCache(
    CacheRecord(
      key: const CacheKey(
        accountId: '7',
        warehouseId: 11,
        namespace: 'inventory',
        entityKey: 'page-1',
      ),
      payload: const {'value': 1},
      schemaVersion: 1,
      fetchedAt: now,
      expiresAt: now.add(const Duration(days: 1)),
    ),
  );
  await store.writeCache(
    CacheRecord(
      key: const CacheKey(
        accountId: '8',
        warehouseId: 12,
        namespace: 'inventory',
        entityKey: 'page-1',
      ),
      payload: const {'value': 2},
      schemaVersion: 1,
      fetchedAt: now,
      expiresAt: now.add(const Duration(days: 1)),
    ),
  );
  await store.saveDraft(
    DocumentDraft(
      id: 'draft-7',
      accountId: '7',
      warehouseId: 11,
      payload: const {},
      attachmentStagingIds: const ['draft-file'],
      createdAt: now,
      updatedAt: now,
    ),
  );
  await store.enqueue(
    OutboxOperation(
      operationId: 'operation-7',
      idempotencyKey: 'key-7',
      accountId: '7',
      warehouseId: 11,
      kind: OutboxOperationKind.documentCreate,
      payload: const {},
      state: OutboxState.queued,
      createdAt: now,
    ),
    const {},
  );

  var snapshot = await ownership.inspectAccount('7');
  expect(snapshot.cacheEntries, 1);
  expect(snapshot.drafts, 1);
  expect(snapshot.outboxOperations, 1);
  expect(snapshot.draftAttachmentRequestIds, {'draft-file'});

  await ownership.clearAccountCache('7');
  snapshot = await ownership.inspectAccount('7');
  expect(snapshot.cacheEntries, 0);
  expect(snapshot.drafts, 1);
  expect(snapshot.outboxOperations, 1);
  expect((await ownership.inspectAccount('8')).cacheEntries, 1);

  await ownership.clearOwnedAccount('7', preserveDrafts: true);
  snapshot = await ownership.inspectAccount('7');
  expect(snapshot.cacheEntries, 0);
  expect(snapshot.drafts, 1);
  expect(snapshot.outboxOperations, 0);

  await ownership.clearAccountOfflineWork('7');
  expect((await ownership.inspectAccount('7')).drafts, 0);
}

Future<void> _expectCanonicalCacheRevision(
  OfflineStore store,
  OfflineOwnershipStore ownership,
) async {
  final now = DateTime.utc(2026, 7, 14, 9);
  const key = CacheKey(
    accountId: '7',
    warehouseId: 11,
    namespace: 'inventory',
    entityKey: 'page-1',
  );
  Future<void> write(Map<String, Object?> payload) => store.writeCache(
    CacheRecord(
      key: key,
      payload: payload,
      schemaVersion: 1,
      fetchedAt: now,
      expiresAt: now.add(const Duration(hours: 1)),
    ),
  );

  await write(const {
    'a': 1,
    'nested': {
      'x': 2,
      'y': [3, 4],
    },
  });
  final first = (await ownership.inspectAccount('7')).contentIdentities.single;
  await write(const {
    'nested': {
      'y': [3, 4],
      'x': 2,
    },
    'a': 1,
  });
  final reordered = (await ownership.inspectAccount(
    '7',
  )).contentIdentities.single;
  await write(const {
    'a': 1,
    'nested': {
      'x': 9,
      'y': [3, 4],
    },
  });
  final changed = (await ownership.inspectAccount(
    '7',
  )).contentIdentities.single;

  expect(reordered, first);
  expect(changed, isNot(first));
  expect(changed, isNot(contains('nested')));
}

final class _Fixture {
  _Fixture({
    _FakeOwnershipStore? store,
    _FakeOwnedFiles? files,
    _FakeOwnedScans? scans,
    bool keyRotationFails = false,
    OfflineMutationParticipant? participant,
    Duration mutationQuiescenceTimeout = const Duration(seconds: 30),
  }) : store = store ?? _FakeOwnershipStore(),
       files = files ?? _FakeOwnedFiles(),
       scans = scans ?? _FakeOwnedScans() {
    this.store.order = order;
    this.files.order = order;
    this.scans.order = order;
    keys = _FakeKeys(order: order, fails: keyRotationFails);
    service = OfflineOwnershipService(
      store: this.store,
      files: this.files,
      scans: this.scans,
      reviews: reviews,
      databaseKeys: keys,
      mutationQuiescenceTimeout: mutationQuiescenceTimeout,
    );
    if (participant != null) service.attachMutationParticipant(participant);
  }

  final List<String> order = [];
  final _FakeOwnershipStore store;
  final _FakeOwnedFiles files;
  final _FakeOwnedScans scans;
  final _FakeReviews reviews = _FakeReviews();
  late final _FakeKeys keys;
  late final OfflineOwnershipService service;
}

final class _BlockingMutationParticipant implements OfflineMutationParticipant {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  OfflineMutationBlock blockMutations(OfflineMutationScope scope) =>
      _BlockingMutationBlock(started: started, releaseGate: release);
}

final class _BlockingMutationBlock implements OfflineMutationBlock {
  _BlockingMutationBlock({required this.started, required this.releaseGate});

  final Completer<void> started;
  final Completer<void> releaseGate;

  @override
  final Object blockId = Object();

  @override
  void release() {}

  @override
  Future<void> waitForQuiescence() async {
    if (!started.isCompleted) started.complete();
    await releaseGate.future;
  }
}

final class _FakeOwnershipStore implements OfflineOwnershipStore {
  _FakeOwnershipStore({
    Map<String, OfflineStoreOwnershipSnapshot>? snapshots,
    this.clearBlocker,
    this.failOnInspectCall,
  }) : snapshots = snapshots ?? <String, OfflineStoreOwnershipSnapshot>{};

  final Map<String, OfflineStoreOwnershipSnapshot> snapshots;
  final Future<void>? clearBlocker;
  final int? failOnInspectCall;
  int inspectCalls = 0;
  final Completer<void> clearStarted = Completer<void>();
  List<String>? order;
  final List<(String, bool)> clearAccountCalls = [];
  final List<String> clearCacheCalls = [];
  final List<String> clearOfflineWorkCalls = [];
  final List<(String, int)> invalidatedWarehouses = [];
  final List<String> permissionInvalidations = [];
  final List<String> discardedSessionProjections = [];

  @override
  Future<OfflineStoreOwnershipSnapshot> inspectAccount(String accountId) async {
    inspectCalls += 1;
    if (inspectCalls == failOnInspectCall) {
      throw StateError('draft attachment enumeration failed');
    }
    return snapshots[accountId] ?? const OfflineStoreOwnershipSnapshot();
  }

  @override
  Future<void> clearOwnedAccount(
    String accountId, {
    required bool preserveDrafts,
  }) async {
    clearAccountCalls.add((accountId, preserveDrafts));
    if (!clearStarted.isCompleted) clearStarted.complete();
    await clearBlocker;
  }

  @override
  Future<void> clearAccountCache(String accountId) async {
    clearCacheCalls.add(accountId);
  }

  @override
  Future<void> clearAccountOfflineWork(String accountId) async {
    clearOfflineWorkCalls.add(accountId);
  }

  @override
  Future<void> invalidateWarehouseCache({
    required String accountId,
    required int warehouseId,
  }) async {
    invalidatedWarehouses.add((accountId, warehouseId));
  }

  @override
  Future<void> invalidatePermissionScopedCache(String accountId) async {
    permissionInvalidations.add(accountId);
  }

  @override
  Future<void> discardSessionProjection(String accountId) async {
    discardedSessionProjections.add(accountId);
  }

  @override
  Future<void> clearAllSensitiveData() async {
    order?.add('store.clearAll');
  }
}

final class _FakeOwnedFiles implements OfflineOwnedFileStore {
  _FakeOwnedFiles({Map<String, OfflineFileOwnershipSnapshot>? snapshots})
    : snapshots = snapshots ?? <String, OfflineFileOwnershipSnapshot>{};

  final Map<String, OfflineFileOwnershipSnapshot> snapshots;
  List<String>? order;
  final List<(String, Set<String>)> clearAccountCalls = [];
  final List<String> clearedDownloads = [];
  final List<String> clearedStagedTransfers = [];

  @override
  Future<OfflineFileOwnershipSnapshot> inspectAccount(String accountId) async =>
      snapshots[accountId] ?? const OfflineFileOwnershipSnapshot();

  @override
  Future<void> clearAccountFiles(
    String accountId, {
    required Set<String> retainStagedRequestIds,
  }) async {
    clearAccountCalls.add((accountId, Set.of(retainStagedRequestIds)));
  }

  @override
  Future<void> clearDownloads(String accountId) async {
    clearedDownloads.add(accountId);
  }

  @override
  Future<void> clearStagedTransfers(String accountId) async {
    clearedStagedTransfers.add(accountId);
  }

  @override
  Future<void> clearAllFiles() async {
    order?.add('files.clearAll');
  }
}

final class _FakeOwnedScans
    implements OfflineOwnedScanStore, OfflineLookupOwnershipStore {
  _FakeOwnedScans({Map<String, int>? counts})
    : counts = counts ?? <String, int>{};

  final Map<String, int> counts;
  List<String>? order;
  final List<String> clearedAccounts = [];
  final List<String> clearedLookupAccounts = [];
  final List<(String, int)> clearedLookupWarehouses = [];

  @override
  Future<int> countLookupCacheForAccount(String accountId) async => 0;

  @override
  Future<Set<String>> lookupContentIdentitiesForAccount(
    String accountId,
  ) async => const {};

  @override
  Future<void> clearLookupCacheForAccount(String accountId) async {
    clearedLookupAccounts.add(accountId);
  }

  @override
  Future<void> clearLookupCacheForWarehouse(
    String accountId,
    int warehouseId,
  ) async {
    clearedLookupWarehouses.add((accountId, warehouseId));
  }

  @override
  Future<void> clearAllLookupCaches() async {
    order?.add('scans.clearAllLookups');
  }

  @override
  Future<int> countForAccount(String accountId) async => counts[accountId] ?? 0;

  @override
  Future<void> clearSessionsForAccount(String accountId) async {
    clearedAccounts.add(accountId);
  }

  @override
  Future<void> clearAllSessions() async {
    order?.add('scans.clearAllSessions');
  }
}

final class _FakeReviews implements OfflineReviewInvalidator {
  final List<(String, int?)> calls = [];
  final Completer<void> started = Completer<void>();
  Future<void>? blocker;
  bool fails = false;

  @override
  Future<void> invalidate({required String accountId, int? warehouseId}) async {
    calls.add((accountId, warehouseId));
    if (!started.isCompleted) started.complete();
    await blocker;
    if (fails) throw StateError('review invalidation failed');
  }
}

final class _FakeKeys implements OfflineDatabaseKeyManager {
  _FakeKeys({required this.order, required this.fails});

  final List<String> order;
  final bool fails;

  @override
  Future<void> rotateAfterRevocation() async {
    order.add('keys.rotate');
    if (fails) throw StateError('rotation failed');
  }
}
