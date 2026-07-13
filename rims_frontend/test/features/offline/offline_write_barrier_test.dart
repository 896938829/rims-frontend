import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/core/storage/app_secure_storage.dart';
import 'package:rims_frontend/features/attachments/data/services/file_attachment_staging_store.dart';
import 'package:rims_frontend/features/attachments/domain/entities/attachment.dart';
import 'package:rims_frontend/features/attachments/domain/services/attachment_picker.dart';
import 'package:rims_frontend/features/auth/domain/entities/app_user.dart';
import 'package:rims_frontend/features/auth/domain/entities/auth_session.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/auth/domain/repositories/auth_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/cached_auth_repository.dart';
import 'package:rims_frontend/features/offline/data/database/offline_database.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_outbox_repository.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_offline_store.dart';
import 'package:rims_frontend/features/offline/domain/entities/cache_snapshot.dart';
import 'package:rims_frontend/features/offline/domain/entities/document_draft.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_graph.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_ownership_service.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_store.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_state_machine.dart';
import 'package:rims_frontend/features/offline/domain/services/offline_write_barrier.dart';
import 'package:rims_frontend/features/inventory/domain/entities/inventory_item.dart';
import 'package:rims_frontend/features/scanner/domain/entities/scan_data.dart';
import 'package:rims_frontend/features/scanner/domain/services/scan_lookup_cache.dart';
import 'package:rims_frontend/features/scanner/domain/services/scan_session_store.dart';

void main() {
  test(
    'detached nested permit remains active until its future settles',
    () async {
      final barrier = OfflineWriteBarrier();
      final nestedEntered = Completer<void>();
      final nestedRelease = Completer<void>();
      late Future<void> nested;

      await barrier.protect(
        accountId: '7',
        operation: () async {
          nested = barrier.protect(
            accountId: '7',
            operation: () async {
              nestedEntered.complete();
              await nestedRelease.future;
            },
          );
        },
      );
      await nestedEntered.future;
      final block = barrier.blockMutations(
        const OfflineMutationScope.account('7'),
      );
      var drained = false;
      final drain = block.waitForQuiescence().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);

      nestedRelease.complete();
      await nested;
      await drain;
      expect(drained, isTrue);
      block.release();
    },
  );

  test('blocked account wrappers reject reads as well as writes', () async {
    final barrier = OfflineWriteBarrier();
    final store = WriteBarrierOfflineStore(
      delegate: MemoryOfflineStore(),
      barrier: barrier,
    );
    final outbox = WriteBarrierOutboxRepository(
      delegate: MemoryOutboxRepository(stateMachine: OutboxStateMachine()),
      barrier: barrier,
    );
    final block = barrier.blockMutations(
      const OfflineMutationScope.account('7'),
    );

    await expectLater(
      store.listDrafts('7'),
      throwsA(isA<OfflineWriteBlockedException>()),
    );
    expect(await outbox.list('7'), isA<FailureResult<List<OutboxOperation>>>());
    block.release();
  });

  test('the outbox wrapper preserves empty graph validation', () async {
    final repository = WriteBarrierOutboxRepository(
      delegate: MemoryOutboxRepository(stateMachine: OutboxStateMachine()),
      barrier: OfflineWriteBarrier(),
    );

    final result = await repository.enqueueGraph(OutboxGraph(operations: []));

    expect(result, isA<FailureResult<List<dynamic>>>());
  });

  test(
    'the account barrier protects both Drift and web-memory offline stores',
    () async {
      final drift = OfflineDatabase.forTesting(NativeDatabase.memory());
      addTearDown(drift.close);
      for (final rawStore in <OfflineStore>[MemoryOfflineStore(), drift]) {
        final barrier = OfflineWriteBarrier();
        final store = WriteBarrierOfflineStore(
          delegate: rawStore,
          barrier: barrier,
        );
        final block = barrier.blockMutations(
          const OfflineMutationScope.account('7'),
        );
        final now = DateTime.utc(2026, 7, 13);
        final record = CacheRecord(
          key: const CacheKey(
            accountId: '7',
            namespace: 'inventory',
            entityKey: 'page',
          ),
          payload: const {},
          schemaVersion: 1,
          fetchedAt: now,
          expiresAt: now.add(const Duration(days: 1)),
        );

        await expectLater(
          store.writeCache(record),
          throwsA(isA<OfflineWriteBlockedException>()),
        );
        block.release();
        await store.writeCache(record);

        expect(
          await rawStore.readCache(record.key, schemaVersion: 1),
          isNotNull,
        );
      }
    },
  );

  test(
    'revocation drains an entered draft and cache write before cleanup and rejects later writes',
    () async {
      final barrier = OfflineWriteBarrier();
      final rawStore = MemoryOfflineStore();
      final store = WriteBarrierOfflineStore(
        delegate: rawStore,
        barrier: barrier,
      );
      final keys = MemoryOfflineDatabaseKeyManager();
      final ownership = _service(
        store: rawStore,
        scans: const _NoopScans(),
        keys: keys,
        participants: [barrier],
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      final now = DateTime.utc(2026, 7, 13);
      final activeWrite = barrier.protect(
        accountId: '7',
        operation: () async {
          entered.complete();
          await release.future;
          await store.writeCache(
            CacheRecord(
              key: const CacheKey(
                accountId: '7',
                namespace: 'inventory',
                entityKey: 'late-cache',
              ),
              payload: const {},
              schemaVersion: 1,
              fetchedAt: now,
              expiresAt: now.add(const Duration(days: 1)),
            ),
          );
          await store.saveDraft(
            DocumentDraft(
              id: 'late-draft',
              accountId: '7',
              warehouseId: 1,
              payload: const {},
              createdAt: now,
              updatedAt: now,
            ),
          );
        },
      );
      await entered.future;

      final revocation = ownership.apply(
        const OfflineOwnershipIntent.revocation(accountId: '7'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(keys.generation, 0);
      await expectLater(
        store.saveDraft(
          DocumentDraft(
            id: 'blocked-draft',
            accountId: '7',
            warehouseId: 1,
            payload: const {},
            createdAt: now,
            updatedAt: now,
          ),
        ),
        throwsA(isA<OfflineWriteBlockedException>()),
      );

      release.complete();
      await activeWrite;
      final report = await revocation;

      expect(report.completed, isTrue);
      expect(keys.generation, 1);
      expect((await rawStore.inspectAccount('7')).cacheEntries, 0);
      expect((await rawStore.inspectAccount('7')).drafts, 0);
    },
  );

  test(
    'clear offline work holds one write snapshot through drain recount and confirmation',
    () async {
      final barrier = OfflineWriteBarrier();
      final rawStore = MemoryOfflineStore();
      final store = WriteBarrierOfflineStore(
        delegate: rawStore,
        barrier: barrier,
      );
      final ownership = _service(
        store: rawStore,
        scans: const _NoopScans(),
        keys: MemoryOfflineDatabaseKeyManager(),
        participants: [barrier],
      );
      final preview = await ownership.preview(
        accountId: '7',
        command: OfflineClearCommand.offlineWork,
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      final now = DateTime.utc(2026, 7, 13);
      final autosave = barrier.protect(
        accountId: '7',
        operation: () async {
          entered.complete();
          await release.future;
          await store.saveDraft(
            DocumentDraft(
              id: 'autosave',
              accountId: '7',
              warehouseId: 1,
              payload: const {},
              createdAt: now,
              updatedAt: now,
            ),
          );
        },
      );
      await entered.future;

      final clearing = ownership.executeClear(preview);
      await Future<void>.delayed(Duration.zero);
      expect((await rawStore.inspectAccount('7')).drafts, 0);

      release.complete();
      await autosave;
      final changed = await clearing;

      expect(changed.requiresReconfirmation, isTrue);
      expect(changed.currentPreview?.counts.drafts, 1);
      expect((await rawStore.inspectAccount('7')).drafts, 1);

      final cleared = await ownership.executeClear(changed.currentPreview!);
      expect(cleared.completed, isTrue);
      expect((await rawStore.inspectAccount('7')).drafts, 0);
    },
  );

  test(
    'clear preview drains entered writes and releases its snapshot barrier afterward',
    () async {
      final barrier = OfflineWriteBarrier();
      final rawStore = MemoryOfflineStore();
      final store = WriteBarrierOfflineStore(
        delegate: rawStore,
        barrier: barrier,
      );
      final ownership = _service(
        store: rawStore,
        scans: const _NoopScans(),
        keys: MemoryOfflineDatabaseKeyManager(),
        participants: [barrier],
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      final now = DateTime.utc(2026, 7, 13);
      final activeWrite = barrier.protect(
        accountId: '7',
        operation: () async {
          entered.complete();
          await release.future;
          await store.saveDraft(
            DocumentDraft(
              id: 'before-preview',
              accountId: '7',
              warehouseId: 1,
              payload: const {},
              createdAt: now,
              updatedAt: now,
            ),
          );
        },
      );
      await entered.future;

      final pendingPreview = ownership.preview(
        accountId: '7',
        command: OfflineClearCommand.offlineWork,
      );
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        store.saveDraft(
          DocumentDraft(
            id: 'blocked-during-preview',
            accountId: '7',
            warehouseId: 1,
            payload: const {},
            createdAt: now,
            updatedAt: now,
          ),
        ),
        throwsA(isA<OfflineWriteBlockedException>()),
      );

      release.complete();
      await activeWrite;
      final preview = await pendingPreview;
      expect(preview.counts.drafts, 1);

      await store.saveDraft(
        DocumentDraft(
          id: 'after-preview',
          accountId: '7',
          warehouseId: 1,
          payload: const {},
          createdAt: now,
          updatedAt: now,
        ),
      );
      expect((await rawStore.inspectAccount('7')).drafts, 2);
    },
  );

  test(
    'same-account login releases a retained logout barrier before writing its new projection',
    () async {
      final barrier = OfflineWriteBarrier();
      final rawStore = MemoryOfflineStore();
      final guardedStore = WriteBarrierOfflineStore(
        delegate: rawStore,
        barrier: barrier,
      );
      final ownership = _service(
        store: rawStore,
        scans: const _NoopScans(),
        keys: MemoryOfflineDatabaseKeyManager(),
        participants: [barrier],
      );
      await ownership.apply(
        const OfflineOwnershipIntent.logout(accountId: '7'),
      );
      final storage = _SessionStorage();
      final delegate = _PendingAuthRepository(storage);
      final repository = CachedAuthRepository(
        delegate: delegate,
        store: guardedStore,
        tokenStorage: storage,
        accountStorage: storage,
        revocationStorage: storage,
        onSessionRevoked: () {},
        ownershipCoordinator: ownership,
      );

      final result = await repository.login(
        username: 'alice',
        password: 'secret',
      );

      expect(result, isA<Success<AuthSession>>());
      expect((await rawStore.inspectAccount('7')).cacheEntries, 1);
      expect(ownership.canAccessOfflineData('7'), isTrue);
    },
  );

  test('reauthentication lease keeps retained blocks until finalize', () async {
    final barrier = OfflineWriteBarrier();
    final ownership = _service(
      store: MemoryOfflineStore(),
      scans: const _NoopScans(),
      keys: MemoryOfflineDatabaseKeyManager(),
      participants: [barrier],
    );
    expect(
      (await ownership.apply(
        const OfflineOwnershipIntent.tokenExpiry(accountId: '7'),
      )).completed,
      isTrue,
    );
    expect(ownership.canSync('7'), isFalse);

    final abandoned = await ownership.prepareReauthentication(accountId: '7');
    expect(abandoned.report.completed, isTrue);
    expect(ownership.canAccessOfflineData('7'), isFalse);
    expect(abandoned.rollback(), const Success<void>(null));
    expect(ownership.canSync('7'), isFalse);

    final accepted = await ownership.prepareReauthentication(accountId: '7');
    expect(ownership.canAccessOfflineData('7'), isFalse);
    final finalized = await accepted.finalize();
    expect(finalized, isA<Success<OfflineOwnershipReport>>());
    expect(ownership.canAccessOfflineData('7'), isTrue);
    expect(ownership.canSync('7'), isTrue);
  });

  test(
    'empty reauthentication lease cannot bypass a later global block',
    () async {
      final barrier = OfflineWriteBarrier();
      final rawStore = MemoryOfflineStore();
      final guardedStore = WriteBarrierOfflineStore(
        delegate: rawStore,
        barrier: barrier,
      );
      final ownership = _service(
        store: rawStore,
        scans: const _NoopScans(),
        keys: MemoryOfflineDatabaseKeyManager(),
        participants: [barrier],
      );
      final lease = await ownership.prepareReauthentication(accountId: '7');
      final record = _ownedCacheRecord('7', 'empty-lease');
      final global = barrier.blockMutations(const OfflineMutationScope.all());

      await expectLater(
        lease.runScopedWrite(() => guardedStore.writeCache(record)),
        throwsA(isA<OfflineWriteBlockedException>()),
      );
      global.release();
      await lease.runScopedWrite(() => guardedStore.writeCache(record));

      expect(await rawStore.readCache(record.key, schemaVersion: 1), isNotNull);
    },
  );

  test(
    'lease permits only captured blocks and rejects a later global block',
    () async {
      final barrier = OfflineWriteBarrier();
      final rawStore = MemoryOfflineStore();
      final guardedStore = WriteBarrierOfflineStore(
        delegate: rawStore,
        barrier: barrier,
      );
      final ownership = _service(
        store: rawStore,
        scans: const _NoopScans(),
        keys: MemoryOfflineDatabaseKeyManager(),
        participants: [barrier],
      );
      await ownership.apply(
        const OfflineOwnershipIntent.tokenExpiry(accountId: '7'),
      );
      final lease = await ownership.prepareReauthentication(accountId: '7');
      final first = _ownedCacheRecord('7', 'captured');
      await lease.runScopedWrite(() => guardedStore.writeCache(first));

      final global = barrier.blockMutations(const OfflineMutationScope.all());
      final second = _ownedCacheRecord('7', 'new-global');
      await expectLater(
        lease.runScopedWrite(() => guardedStore.writeCache(second)),
        throwsA(isA<OfflineWriteBlockedException>()),
      );
      global.release();
      await lease.runScopedWrite(() => guardedStore.writeCache(second));

      expect(await rawStore.readCache(second.key, schemaVersion: 1), isNotNull);
    },
  );

  test('scoped lease is not blocked by an unrelated account', () async {
    final barrier = OfflineWriteBarrier();
    final rawStore = MemoryOfflineStore();
    final guardedStore = WriteBarrierOfflineStore(
      delegate: rawStore,
      barrier: barrier,
    );
    final ownership = _service(
      store: rawStore,
      scans: const _NoopScans(),
      keys: MemoryOfflineDatabaseKeyManager(),
      participants: [barrier],
    );
    final lease = await ownership.prepareReauthentication(accountId: '7');
    final unrelated = barrier.blockMutations(
      const OfflineMutationScope.account('8'),
    );
    final record = _ownedCacheRecord('7', 'unrelated');

    await lease.runScopedWrite(() => guardedStore.writeCache(record));
    unrelated.release();

    expect(await rawStore.readCache(record.key, schemaVersion: 1), isNotNull);
  });

  test(
    'finalize release failure retains a fallback guard until retry succeeds',
    () async {
      final barrier = OfflineWriteBarrier();
      final throwing = _ThrowingMutationParticipant();
      final ownership = _service(
        store: MemoryOfflineStore(),
        scans: const _NoopScans(),
        keys: MemoryOfflineDatabaseKeyManager(),
        participants: [barrier, throwing],
      );
      await ownership.apply(
        const OfflineOwnershipIntent.tokenExpiry(accountId: '7'),
      );
      final failedLease = await ownership.prepareReauthentication(
        accountId: '7',
      );
      throwing.throwOnReleaseCall = 1;

      final failed = await failedLease.finalize();

      expect(failed, isA<FailureResult<OfflineOwnershipReport>>());
      expect(ownership.canAccessOfflineData('7'), isFalse);
      expect(ownership.canSync('7'), isFalse);
      await expectLater(
        barrier.protect(accountId: '7', operation: () async {}),
        throwsA(isA<OfflineWriteBlockedException>()),
      );

      throwing.throwOnReleaseCall = null;
      final retryLease = await ownership.prepareReauthentication(
        accountId: '7',
      );
      expect(
        await retryLease.finalize(),
        isA<Success<OfflineOwnershipReport>>(),
      );
      expect(ownership.canAccessOfflineData('7'), isTrue);
      expect(ownership.canSync('7'), isTrue);
      expect(throwing.activeBlocks, 0);
    },
  );

  test(
    'pending reauthentication lease does not release after a simulated crash',
    () async {
      final barrier = OfflineWriteBarrier();
      final ownership = _service(
        store: MemoryOfflineStore(),
        scans: const _NoopScans(),
        keys: MemoryOfflineDatabaseKeyManager(),
        participants: [barrier],
      );
      await ownership.apply(
        const OfflineOwnershipIntent.tokenExpiry(accountId: '7'),
      );

      final pending = await ownership.prepareReauthentication(accountId: '7');

      expect(pending.report.completed, isTrue);
      expect(ownership.canAccessOfflineData('7'), isFalse);
      expect(ownership.canSync('7'), isFalse);
    },
  );

  for (final reason in const [
    OfflineOwnershipReason.accountSwitch,
    OfflineOwnershipReason.revocation,
    OfflineOwnershipReason.permissionRefresh,
    OfflineOwnershipReason.warehouseSwitch,
  ]) {
    test(
      '${reason.name} only releases the latest successful overlapping attempt',
      () async {
        final barrier = OfflineWriteBarrier();
        final store = _AttemptControlledOwnershipStore(reason, [
          _ControlledOwnershipAttempt.blocked(),
          _ControlledOwnershipAttempt.failed(),
          _ControlledOwnershipAttempt.successful(),
        ]);
        final ownership = OfflineOwnershipService(
          store: store,
          files: const _NoopFiles(),
          scans: const _NoopScans(),
          reviews: const _NoopReviews(),
          databaseKeys: MemoryOfflineDatabaseKeyManager(),
          mutationParticipants: [barrier],
        );
        final first = ownership.apply(_intentFor(reason));
        await store.attempts.first.started.future;

        final second = ownership.apply(_intentFor(reason));
        await Future<void>.delayed(Duration.zero);
        expect(store.attempts[1].started.isCompleted, isFalse);
        store.attempts.first.release.complete();
        expect((await first).completed, isTrue);
        expect((await second).completed, isFalse);

        expect(ownership.canAccessOfflineData('7'), isFalse);
        await expectLater(
          barrier.protect(accountId: '7', operation: () async {}),
          throwsA(isA<OfflineWriteBlockedException>()),
        );
        await ownership.apply(
          const OfflineOwnershipIntent.reauthenticated(accountId: '7'),
        );
        expect(ownership.canAccessOfflineData('7'), isFalse);
        if (reason == OfflineOwnershipReason.accountSwitch) {
          expect(ownership.canAccessOfflineData('8'), isTrue);
          await barrier.protect(accountId: '8', operation: () async {});
        }

        expect((await ownership.apply(_intentFor(reason))).completed, isTrue);
        if (reason == OfflineOwnershipReason.accountSwitch ||
            reason == OfflineOwnershipReason.revocation) {
          expect(ownership.canAccessOfflineData('7'), isFalse);
          await ownership.apply(
            const OfflineOwnershipIntent.reauthenticated(accountId: '7'),
          );
        }
        expect(ownership.canAccessOfflineData('7'), isTrue);
        if (reason == OfflineOwnershipReason.accountSwitch) {
          expect(ownership.canAccessOfflineData('8'), isTrue);
          await barrier.protect(accountId: '8', operation: () async {});
        }
        await barrier.protect(accountId: '7', operation: () async {});
      },
    );

    test(
      '${reason.name} releases when the newer overlapping attempt succeeds',
      () async {
        final barrier = OfflineWriteBarrier();
        final store = _AttemptControlledOwnershipStore(reason, [
          _ControlledOwnershipAttempt.blocked(fails: true),
          _ControlledOwnershipAttempt.successful(),
        ]);
        final ownership = OfflineOwnershipService(
          store: store,
          files: const _NoopFiles(),
          scans: const _NoopScans(),
          reviews: const _NoopReviews(),
          databaseKeys: MemoryOfflineDatabaseKeyManager(),
          mutationParticipants: [barrier],
        );
        final first = ownership.apply(_intentFor(reason));
        await store.attempts.first.started.future;
        final second = ownership.apply(_intentFor(reason));
        store.attempts.first.release.complete();

        expect((await first).completed, isFalse);
        expect((await second).completed, isTrue);
        if (reason == OfflineOwnershipReason.accountSwitch ||
            reason == OfflineOwnershipReason.revocation) {
          await ownership.apply(
            const OfflineOwnershipIntent.reauthenticated(accountId: '7'),
          );
        }
        expect(ownership.canAccessOfflineData('7'), isTrue);
        if (reason == OfflineOwnershipReason.accountSwitch) {
          expect(ownership.canAccessOfflineData('8'), isTrue);
          await barrier.protect(accountId: '8', operation: () async {});
        }
        await barrier.protect(accountId: '7', operation: () async {});
      },
    );
  }

  test('overlapping account switches release superseded targets without '
      'unblocking the latest target', () async {
    final barrier = OfflineWriteBarrier();
    final store =
        _AttemptControlledOwnershipStore(OfflineOwnershipReason.accountSwitch, [
          _ControlledOwnershipAttempt.blocked(),
          _ControlledOwnershipAttempt.blocked(),
        ]);
    final ownership = OfflineOwnershipService(
      store: store,
      files: const _NoopFiles(),
      scans: const _NoopScans(),
      reviews: const _NoopReviews(),
      databaseKeys: MemoryOfflineDatabaseKeyManager(),
      mutationParticipants: [barrier],
    );

    final first = ownership.apply(
      const OfflineOwnershipIntent.accountSwitch(
        previousAccountId: '7',
        currentAccountId: '8',
      ),
    );
    await store.attempts[0].started.future;
    final second = ownership.apply(
      const OfflineOwnershipIntent.accountSwitch(
        previousAccountId: '7',
        currentAccountId: '9',
      ),
    );

    store.attempts[0].release.complete();
    expect((await first).completed, isTrue);
    await store.attempts[1].started.future;
    expect(ownership.canAccessOfflineData('8'), isTrue);
    expect(ownership.canAccessOfflineData('9'), isFalse);
    await barrier.protect(accountId: '8', operation: () async {});
    await expectLater(
      barrier.protect(accountId: '9', operation: () async {}),
      throwsA(isA<OfflineWriteBlockedException>()),
    );

    store.attempts[1].release.complete();
    expect((await second).completed, isTrue);
    expect(ownership.canAccessOfflineData('9'), isTrue);
    expect(ownership.canAccessOfflineData('7'), isFalse);
    await ownership.apply(
      const OfflineOwnershipIntent.reauthenticated(accountId: '7'),
    );
    expect(ownership.canAccessOfflineData('7'), isTrue);
    expect(ownership.debugGenerationMetadataEntryCount, 0);
  });

  test(
    'account switches with different previous accounts share a target safely',
    () async {
      final barrier = OfflineWriteBarrier();
      final store = _AttemptControlledOwnershipStore(
        OfflineOwnershipReason.accountSwitch,
        [
          _ControlledOwnershipAttempt.blocked(fails: true),
          _ControlledOwnershipAttempt.blocked(),
          _ControlledOwnershipAttempt.successful(),
        ],
      );
      final ownership = OfflineOwnershipService(
        store: store,
        files: const _NoopFiles(),
        scans: const _NoopScans(),
        reviews: const _NoopReviews(),
        databaseKeys: MemoryOfflineDatabaseKeyManager(),
        mutationParticipants: [barrier],
      );

      final first = ownership.apply(
        const OfflineOwnershipIntent.accountSwitch(
          previousAccountId: '7',
          currentAccountId: '9',
        ),
      );
      await store.attempts[0].started.future;
      final second = ownership.apply(
        const OfflineOwnershipIntent.accountSwitch(
          previousAccountId: '8',
          currentAccountId: '9',
        ),
      );
      store.attempts[0].release.complete();
      expect((await first).completed, isFalse);
      await store.attempts[1].started.future;
      expect(ownership.canAccessOfflineData('7'), isFalse);
      expect(ownership.canAccessOfflineData('9'), isFalse);

      store.attempts[1].release.complete();
      expect((await second).completed, isTrue);
      expect(ownership.canAccessOfflineData('9'), isTrue);
      await ownership.apply(
        const OfflineOwnershipIntent.reauthenticated(accountId: '8'),
      );
      expect(ownership.canAccessOfflineData('8'), isTrue);
      expect(ownership.canAccessOfflineData('7'), isFalse);

      expect(
        (await ownership.apply(
          const OfflineOwnershipIntent.accountSwitch(
            previousAccountId: '7',
            currentAccountId: '9',
          ),
        )).completed,
        isTrue,
      );
      await ownership.apply(
        const OfflineOwnershipIntent.reauthenticated(accountId: '7'),
      );
      expect(ownership.canAccessOfflineData('7'), isTrue);
      expect(ownership.canAccessOfflineData('9'), isTrue);
      expect(ownership.debugGenerationMetadataEntryCount, 0);
    },
  );

  for (final secondaryAttemptFails in [false, true]) {
    test(
      'account switch secondary ${secondaryAttemptFails ? 'failure' : 'success'} '
      'cannot consume an earlier primary block',
      () async {
        final barrier = OfflineWriteBarrier();
        final store = _AttemptControlledOwnershipStore(
          OfflineOwnershipReason.accountSwitch,
          [
            _ControlledOwnershipAttempt.successful(),
            secondaryAttemptFails
                ? _ControlledOwnershipAttempt.failed()
                : _ControlledOwnershipAttempt.successful(),
            _ControlledOwnershipAttempt.successful(),
          ],
        );
        final ownership = OfflineOwnershipService(
          store: store,
          files: const _NoopFiles(),
          scans: const _NoopScans(),
          reviews: const _NoopReviews(),
          databaseKeys: MemoryOfflineDatabaseKeyManager(),
          mutationParticipants: [barrier],
        );

        expect(
          (await ownership.apply(
            const OfflineOwnershipIntent.accountSwitch(
              previousAccountId: '8',
              currentAccountId: '9',
            ),
          )).completed,
          isTrue,
        );
        expect(ownership.canAccessOfflineData('8'), isFalse);

        expect(
          (await ownership.apply(
            const OfflineOwnershipIntent.accountSwitch(
              previousAccountId: '7',
              currentAccountId: '8',
            ),
          )).completed,
          isNot(secondaryAttemptFails),
        );
        expect(ownership.canAccessOfflineData('8'), isFalse);
        await expectLater(
          barrier.protect(accountId: '8', operation: () async {}),
          throwsA(isA<OfflineWriteBlockedException>()),
        );

        await ownership.apply(
          const OfflineOwnershipIntent.reauthenticated(accountId: '8'),
        );
        expect(ownership.canAccessOfflineData('8'), isTrue);

        if (secondaryAttemptFails) {
          expect(
            (await ownership.apply(
              const OfflineOwnershipIntent.accountSwitch(
                previousAccountId: '7',
                currentAccountId: '8',
              ),
            )).completed,
            isTrue,
          );
        }
        await ownership.apply(
          const OfflineOwnershipIntent.reauthenticated(accountId: '7'),
        );
        expect(ownership.canAccessOfflineData('7'), isTrue);
        expect(ownership.debugGenerationMetadataEntryCount, 0);
      },
    );
  }

  for (final throwAt in [0, 1]) {
    test(
      'participant acquisition throw at index $throwAt releases attempt',
      () async {
        final participants = [
          _ThrowingMutationParticipant(throwOnAcquire: throwAt == 0),
          _ThrowingMutationParticipant(throwOnAcquire: throwAt == 1),
        ];
        final ownership = OfflineOwnershipService(
          store: MemoryOfflineStore(),
          files: const _NoopFiles(),
          scans: const _NoopScans(),
          reviews: const _NoopReviews(),
          databaseKeys: MemoryOfflineDatabaseKeyManager(),
          mutationParticipants: participants,
        );

        expect(
          () => ownership.apply(
            const OfflineOwnershipIntent.permissionRefresh(accountId: '7'),
          ),
          throwsA(isA<StateError>()),
        );
        expect(ownership.canAccessOfflineData('7'), isTrue);
        expect(ownership.debugGenerationMetadataEntryCount, 0);
        for (final participant in participants) {
          participant.throwOnAcquire = false;
        }
        expect(
          (await ownership.apply(
            const OfflineOwnershipIntent.permissionRefresh(accountId: '7'),
          )).completed,
          isTrue,
        );
        expect(ownership.debugGenerationMetadataEntryCount, 0);
      },
    );
  }

  test(
    'acquisition rollback releases every handle and retains failed releases',
    () async {
      final releaseThrowing = _ThrowingMutationParticipant()
        ..throwOnReleaseCall = 1;
      final barrier = OfflineWriteBarrier();
      final acquireThrowing = _ThrowingMutationParticipant(
        throwOnAcquire: true,
      );
      final ownership = OfflineOwnershipService(
        store: MemoryOfflineStore(),
        files: const _NoopFiles(),
        scans: const _NoopScans(),
        reviews: const _NoopReviews(),
        databaseKeys: MemoryOfflineDatabaseKeyManager(),
        mutationParticipants: [releaseThrowing, barrier, acquireThrowing],
      );

      await expectLater(
        ownership.apply(
          const OfflineOwnershipIntent.permissionRefresh(accountId: '7'),
        ),
        throwsA(isA<OfflineMutationAcquisitionException>()),
      );

      expect(releaseThrowing.activeBlocks, 1);
      expect(ownership.canAccessOfflineData('7'), isFalse);
      await expectLater(
        barrier.protect(accountId: '7', operation: () async {}),
        completes,
      );

      releaseThrowing.throwOnReleaseCall = null;
      acquireThrowing.throwOnAcquire = false;
      expect(
        (await ownership.apply(
          const OfflineOwnershipIntent.permissionRefresh(accountId: '7'),
        )).completed,
        isTrue,
      );
      expect(releaseThrowing.activeBlocks, 0);
      expect(ownership.canAccessOfflineData('7'), isTrue);
      expect(ownership.debugGenerationMetadataEntryCount, 0);
    },
  );

  test('acquisition rollback aggregates every release failure', () async {
    final first = _ThrowingMutationParticipant()..throwOnReleaseCall = 1;
    final second = _ThrowingMutationParticipant()..throwOnReleaseCall = 1;
    final acquireThrowing = _ThrowingMutationParticipant(throwOnAcquire: true);
    final ownership = OfflineOwnershipService(
      store: MemoryOfflineStore(),
      files: const _NoopFiles(),
      scans: const _NoopScans(),
      reviews: const _NoopReviews(),
      databaseKeys: MemoryOfflineDatabaseKeyManager(),
      mutationParticipants: [first, second, acquireThrowing],
    );

    final error = await ownership
        .apply(const OfflineOwnershipIntent.permissionRefresh(accountId: '7'))
        .then<Object?>((_) => null, onError: (Object error) => error);

    expect(error, isA<OfflineMutationAcquisitionException>());
    expect(
      (error! as OfflineMutationAcquisitionException).releaseFailures,
      hasLength(2),
    );
    expect(first.releaseCalls, 1);
    expect(second.releaseCalls, 1);
    expect(ownership.canAccessOfflineData('7'), isFalse);

    first.throwOnReleaseCall = null;
    second.throwOnReleaseCall = null;
    acquireThrowing.throwOnAcquire = false;
    expect(
      (await ownership.apply(
        const OfflineOwnershipIntent.permissionRefresh(accountId: '7'),
      )).completed,
      isTrue,
    );
    expect(first.activeBlocks, 0);
    expect(second.activeBlocks, 0);
    expect(ownership.debugGenerationMetadataEntryCount, 0);
  });

  test(
    'preview rollback registers every orphan and overlapping reasons recover them',
    () async {
      final first = _ThrowingMutationParticipant()..throwOnReleaseCall = 1;
      final second = _ThrowingMutationParticipant()..throwOnReleaseCall = 1;
      final barrier = OfflineWriteBarrier();
      final acquireThrowing = _ThrowingMutationParticipant(
        throwOnAcquire: true,
      );
      final store = _AttemptControlledOwnershipStore(
        OfflineOwnershipReason.warehouseSwitch,
        [_ControlledOwnershipAttempt.successful()],
      );
      final ownership = OfflineOwnershipService(
        store: store,
        files: const _NoopFiles(),
        scans: const _NoopScans(),
        reviews: const _NoopReviews(),
        databaseKeys: MemoryOfflineDatabaseKeyManager(),
        mutationParticipants: [first, second, barrier, acquireThrowing],
      );

      expect(
        () => ownership.preview(
          accountId: '7',
          command: OfflineClearCommand.cache,
        ),
        throwsA(isA<OfflineMutationAcquisitionException>()),
      );

      expect(ownership.debugOrphanedMutationBlockCount, 2);
      expect(ownership.canAccessOfflineData('7'), isFalse);
      expect(ownership.canAccessOfflineData('8'), isTrue);
      await expectLater(
        barrier.protect(accountId: '7', operation: () async {}),
        completes,
      );

      acquireThrowing.throwOnAcquire = false;
      expect(
        (await ownership.apply(
          const OfflineOwnershipIntent.permissionRefresh(accountId: '8'),
        )).completed,
        isTrue,
      );
      expect(ownership.debugOrphanedMutationBlockCount, 2);

      first.throwOnReleaseCall = null;
      second.throwOnReleaseCall = second.releaseCalls + 1;
      await expectLater(
        ownership.apply(
          const OfflineOwnershipIntent.warehouseSwitch(
            accountId: '7',
            previousWarehouseId: 1,
            currentWarehouseId: 2,
          ),
        ),
        throwsA(isA<OfflineMutationRecoveryException>()),
      );
      expect(store.callCount, 0);
      expect(ownership.debugOrphanedMutationBlockCount, 1);
      expect(ownership.canAccessOfflineData('7'), isFalse);

      second.throwOnReleaseCall = null;
      expect(
        (await ownership.apply(
          const OfflineOwnershipIntent.warehouseSwitch(
            accountId: '7',
            previousWarehouseId: 1,
            currentWarehouseId: 2,
          ),
        )).completed,
        isTrue,
      );
      expect(store.callCount, 1);
      expect(ownership.debugOrphanedMutationBlockCount, 0);
      expect(ownership.canAccessOfflineData('7'), isTrue);
      expect(first.activeBlocks, 0);
      expect(second.activeBlocks, 0);
      expect(ownership.debugGenerationMetadataEntryCount, 0);
    },
  );

  test(
    'revocation account conversion rollback is centrally recoverable',
    () async {
      final releaseThrowing = _ThrowingMutationParticipant()
        ..throwOnReleaseCall = 1;
      final barrier = OfflineWriteBarrier();
      final acquireThrowing = _ThrowingMutationParticipant(
        throwOnAcquireCall: 2,
      );
      final ownership = OfflineOwnershipService(
        store: MemoryOfflineStore(),
        files: const _NoopFiles(),
        scans: const _NoopScans(),
        reviews: const _NoopReviews(),
        databaseKeys: MemoryOfflineDatabaseKeyManager(),
        mutationParticipants: [releaseThrowing, barrier, acquireThrowing],
      );

      await expectLater(
        ownership.apply(
          const OfflineOwnershipIntent.revocation(accountId: '7'),
        ),
        throwsA(isA<OfflineMutationAcquisitionException>()),
      );

      expect(ownership.debugOrphanedMutationBlockCount, 1);
      expect(ownership.canAccessOfflineData('7'), isFalse);
      await expectLater(
        barrier.protect(accountId: '7', operation: () async {}),
        completes,
      );

      releaseThrowing.throwOnReleaseCall = null;
      acquireThrowing.throwOnAcquireCall = null;
      expect(
        (await ownership.apply(
          const OfflineOwnershipIntent.permissionRefresh(accountId: '7'),
        )).completed,
        isTrue,
      );
      expect(ownership.debugOrphanedMutationBlockCount, 0);
      expect(ownership.canAccessOfflineData('7'), isTrue);
      expect(releaseThrowing.activeBlocks, 0);
      expect(ownership.debugGenerationMetadataEntryCount, 0);
    },
  );

  test(
    'clear execution acquisition rollback is recovered by an ownership retry',
    () async {
      final releaseThrowing = _ThrowingMutationParticipant();
      final barrier = OfflineWriteBarrier();
      final acquireThrowing = _ThrowingMutationParticipant();
      final ownership = OfflineOwnershipService(
        store: MemoryOfflineStore(),
        files: const _NoopFiles(),
        scans: const _NoopScans(),
        reviews: const _NoopReviews(),
        databaseKeys: MemoryOfflineDatabaseKeyManager(),
        mutationParticipants: [releaseThrowing, barrier, acquireThrowing],
      );
      final preview = await ownership.preview(
        accountId: '7',
        command: OfflineClearCommand.cache,
      );
      releaseThrowing.throwOnReleaseCall = releaseThrowing.releaseCalls + 1;
      acquireThrowing.throwOnAcquire = true;

      expect(
        () => ownership.executeClear(preview),
        throwsA(isA<OfflineMutationAcquisitionException>()),
      );

      expect(ownership.debugOrphanedMutationBlockCount, 1);
      expect(ownership.canAccessOfflineData('7'), isFalse);
      await expectLater(
        barrier.protect(accountId: '7', operation: () async {}),
        completes,
      );

      releaseThrowing.throwOnReleaseCall = null;
      acquireThrowing.throwOnAcquire = false;
      expect(
        (await ownership.apply(
          const OfflineOwnershipIntent.warehouseSwitch(
            accountId: '7',
            previousWarehouseId: 1,
            currentWarehouseId: 2,
          ),
        )).completed,
        isTrue,
      );
      expect(ownership.debugOrphanedMutationBlockCount, 0);
      expect(ownership.canAccessOfflineData('7'), isTrue);
      expect(releaseThrowing.activeBlocks, 0);
      expect(ownership.debugGenerationMetadataEntryCount, 0);
    },
  );

  test(
    'reauthentication guard rollback is recovered by an overlapping reason',
    () async {
      final releaseThrowing = _ThrowingMutationParticipant();
      final barrier = OfflineWriteBarrier();
      final acquireThrowing = _ThrowingMutationParticipant();
      final ownership = OfflineOwnershipService(
        store: MemoryOfflineStore(),
        files: const _NoopFiles(),
        scans: const _NoopScans(),
        reviews: const _NoopReviews(),
        databaseKeys: MemoryOfflineDatabaseKeyManager(),
        mutationParticipants: [releaseThrowing, barrier, acquireThrowing],
      );
      expect(
        (await ownership.apply(
          const OfflineOwnershipIntent.tokenExpiry(accountId: '7'),
        )).completed,
        isTrue,
      );
      final lease = await ownership.prepareReauthentication(accountId: '7');
      releaseThrowing.throwOnReleaseCall = 1;
      acquireThrowing.throwOnAcquireCall = 2;

      expect(
        await lease.finalize(),
        isA<FailureResult<OfflineOwnershipReport>>(),
      );
      expect(ownership.debugOrphanedMutationBlockCount, 1);
      expect(ownership.canAccessOfflineData('7'), isFalse);

      releaseThrowing.throwOnReleaseCall = null;
      acquireThrowing.throwOnAcquireCall = null;
      expect(
        (await ownership.apply(
          const OfflineOwnershipIntent.permissionRefresh(accountId: '7'),
        )).completed,
        isTrue,
      );
      expect(ownership.debugOrphanedMutationBlockCount, 0);
      expect(ownership.canAccessOfflineData('7'), isFalse);

      final retryLease = await ownership.prepareReauthentication(
        accountId: '7',
      );
      expect(
        await retryLease.finalize(),
        isA<Success<OfflineOwnershipReport>>(),
      );
      expect(ownership.canAccessOfflineData('7'), isTrue);
      expect(releaseThrowing.activeBlocks, 0);
      expect(ownership.debugOrphanedMutationBlockCount, 0);
      expect(ownership.debugGenerationMetadataEntryCount, 0);
    },
  );

  test(
    'supersede release failure keeps a logical gate and recovers new blocks',
    () async {
      final throwing = _ThrowingMutationParticipant();
      final barrier = OfflineWriteBarrier();
      final ownership = OfflineOwnershipService(
        store: MemoryOfflineStore(),
        files: const _NoopFiles(),
        scans: const _NoopScans(),
        reviews: const _NoopReviews(),
        databaseKeys: MemoryOfflineDatabaseKeyManager(),
        mutationParticipants: [throwing, barrier],
      );
      expect(
        (await ownership.apply(
          const OfflineOwnershipIntent.tokenExpiry(accountId: '7'),
        )).completed,
        isTrue,
      );
      throwing.throwOnReleaseCall = 1;

      await expectLater(
        ownership.apply(
          const OfflineOwnershipIntent.tokenExpiry(accountId: '7'),
        ),
        throwsA(isA<OfflineMutationReleaseException>()),
      );

      expect(ownership.canAccessOfflineData('7'), isFalse);
      expect(ownership.debugOrphanedMutationBlockCount, 1);
      await expectLater(
        barrier.protect(accountId: '7', operation: () async {}),
        throwsA(isA<OfflineWriteBlockedException>()),
      );

      throwing.throwOnReleaseCall = null;
      expect(
        (await ownership.apply(
          const OfflineOwnershipIntent.tokenExpiry(accountId: '7'),
        )).completed,
        isTrue,
      );
      expect(ownership.debugOrphanedMutationBlockCount, 0);
      expect(ownership.canAccessOfflineData('7'), isFalse);
      await ownership.apply(
        const OfflineOwnershipIntent.reauthenticated(accountId: '7'),
      );
      expect(ownership.canAccessOfflineData('7'), isTrue);
      expect(throwing.activeBlocks, 0);
      expect(ownership.debugGenerationMetadataEntryCount, 0);
    },
  );

  for (final reason in const [
    OfflineOwnershipReason.tokenExpiry,
    OfflineOwnershipReason.revocation,
    OfflineOwnershipReason.accountSwitch,
  ]) {
    for (final throwAt in [0, 1]) {
      test('${reason.name} replacement acquisition failure at participant '
          '$throwAt preserves the old retained generation', () async {
        final participants = [
          _ThrowingMutationParticipant(),
          _ThrowingMutationParticipant(),
        ];
        final ownership = OfflineOwnershipService(
          store: MemoryOfflineStore(),
          files: const _NoopFiles(),
          scans: const _NoopScans(),
          reviews: const _NoopReviews(),
          databaseKeys: MemoryOfflineDatabaseKeyManager(),
          mutationParticipants: participants,
        );
        expect((await ownership.apply(_intentFor(reason))).completed, isTrue);
        expect(ownership.canAccessOfflineData('7'), isFalse);
        expect(
          participants.map((value) => value.activeBlocks),
          everyElement(1),
        );

        participants[throwAt].throwOnAcquire = true;
        expect(
          () => ownership.apply(_intentFor(reason)),
          throwsA(isA<StateError>()),
        );
        expect(ownership.canAccessOfflineData('7'), isFalse);
        expect(
          participants.map((value) => value.activeBlocks),
          everyElement(1),
        );

        await ownership.apply(
          const OfflineOwnershipIntent.reauthenticated(accountId: '7'),
        );
        expect(ownership.canAccessOfflineData('7'), isTrue);
        expect(
          participants.map((value) => value.activeBlocks),
          everyElement(0),
        );
      });
    }
  }

  for (final throwParticipant in [0, 1]) {
    test('accountSwitch secondary acquisition failure at participant '
        '$throwParticipant preserves target primary state', () async {
      final participants = [
        _ThrowingMutationParticipant(),
        _ThrowingMutationParticipant(),
      ];
      final ownership = OfflineOwnershipService(
        store: MemoryOfflineStore(),
        files: const _NoopFiles(),
        scans: const _NoopScans(),
        reviews: const _NoopReviews(),
        databaseKeys: MemoryOfflineDatabaseKeyManager(),
        mutationParticipants: participants,
      );
      await ownership.apply(
        const OfflineOwnershipIntent.accountSwitch(
          previousAccountId: '8',
          currentAccountId: '9',
        ),
      );
      expect(ownership.canAccessOfflineData('8'), isFalse);
      participants[throwParticipant].throwOnAcquireCall = 4;

      expect(
        () => ownership.apply(
          const OfflineOwnershipIntent.accountSwitch(
            previousAccountId: '7',
            currentAccountId: '8',
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(ownership.canAccessOfflineData('8'), isFalse);
      expect(participants.map((value) => value.activeBlocks), everyElement(1));

      await ownership.apply(
        const OfflineOwnershipIntent.reauthenticated(accountId: '8'),
      );
      expect(ownership.canAccessOfflineData('8'), isTrue);
      expect(participants.map((value) => value.activeBlocks), everyElement(0));
    });
  }

  for (final reason in const [
    OfflineOwnershipReason.revocation,
    OfflineOwnershipReason.tokenExpiry,
    OfflineOwnershipReason.accountSwitch,
    OfflineOwnershipReason.permissionRefresh,
    OfflineOwnershipReason.warehouseSwitch,
  ]) {
    test(
      '${reason.name} quiescence failure remains blocked until retry',
      () async {
        final barrier = OfflineWriteBarrier();
        final participant = _ThrowingMutationParticipant(throwOnWait: true);
        final store = _AttemptControlledOwnershipStore(reason, [
          _ControlledOwnershipAttempt.successful(),
        ]);
        final ownership = OfflineOwnershipService(
          store: store,
          files: const _NoopFiles(),
          scans: const _NoopScans(),
          reviews: const _NoopReviews(),
          databaseKeys: MemoryOfflineDatabaseKeyManager(),
          mutationParticipants: [barrier, participant],
        );

        final failed = await ownership.apply(_intentFor(reason));

        expect(failed.completed, isFalse);
        expect(store.callCount, 0);
        expect(ownership.canAccessOfflineData('7'), isFalse);
        expect(ownership.canSync('7'), isFalse);
        await expectLater(
          barrier.protect(accountId: '7', operation: () async {}),
          throwsA(isA<OfflineWriteBlockedException>()),
        );

        participant.throwOnWait = false;
        expect((await ownership.apply(_intentFor(reason))).completed, isTrue);
        if (reason == OfflineOwnershipReason.revocation ||
            reason == OfflineOwnershipReason.tokenExpiry ||
            reason == OfflineOwnershipReason.accountSwitch) {
          await ownership.apply(
            const OfflineOwnershipIntent.reauthenticated(accountId: '7'),
          );
        }
        expect(ownership.canAccessOfflineData('7'), isTrue);
        await barrier.protect(accountId: '7', operation: () async {});
      },
    );
  }

  test(
    'clear command quiescence failure remains blocked until retry',
    () async {
      final barrier = OfflineWriteBarrier();
      final participant = _ThrowingMutationParticipant();
      final store = MemoryOfflineStore();
      final now = DateTime.utc(2026, 7, 14);
      await store.writeCache(
        CacheRecord(
          key: const CacheKey(
            accountId: '7',
            namespace: 'inventory',
            entityKey: 'page=1',
          ),
          payload: const {'value': 1},
          schemaVersion: 1,
          fetchedAt: now,
          expiresAt: now.add(const Duration(days: 1)),
        ),
      );
      final ownership = OfflineOwnershipService(
        store: store,
        files: const _NoopFiles(),
        scans: const _NoopScans(),
        reviews: const _NoopReviews(),
        databaseKeys: MemoryOfflineDatabaseKeyManager(),
        mutationParticipants: [barrier, participant],
      );
      final preview = await ownership.preview(
        accountId: '7',
        command: OfflineClearCommand.cache,
      );
      participant.throwOnWait = true;

      final failed = await ownership.executeClear(preview);

      expect(failed.completed, isFalse);
      expect((await store.inspectAccount('7')).cacheEntries, 1);
      expect(ownership.canAccessOfflineData('7'), isFalse);
      await expectLater(
        barrier.protect(accountId: '7', operation: () async {}),
        throwsA(isA<OfflineWriteBlockedException>()),
      );

      participant.throwOnWait = false;
      expect((await ownership.executeClear(preview)).completed, isTrue);
      expect((await store.inspectAccount('7')).cacheEntries, 0);
      expect(ownership.canAccessOfflineData('7'), isTrue);
    },
  );

  test(
    'revocation retained-block acquisition failure releases all handles',
    () async {
      final participant = _ThrowingMutationParticipant(throwOnAcquireCall: 2);
      final ownership = OfflineOwnershipService(
        store: MemoryOfflineStore(),
        files: const _NoopFiles(),
        scans: const _NoopScans(),
        reviews: const _NoopReviews(),
        databaseKeys: MemoryOfflineDatabaseKeyManager(),
        mutationParticipants: [participant],
      );

      await expectLater(
        ownership.apply(
          const OfflineOwnershipIntent.revocation(accountId: '7'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(participant.activeBlocks, 0);
      expect(ownership.canAccessOfflineData('7'), isTrue);
      expect(ownership.debugGenerationMetadataEntryCount, 0);

      participant.throwOnAcquireCall = null;
      expect(
        (await ownership.apply(
          const OfflineOwnershipIntent.revocation(accountId: '7'),
        )).completed,
        isTrue,
      );
      expect(participant.activeBlocks, 1);
      await ownership.apply(
        const OfflineOwnershipIntent.reauthenticated(accountId: '7'),
      );
      expect(participant.activeBlocks, 0);
      expect(ownership.debugGenerationMetadataEntryCount, 0);
    },
  );

  test('completed ownership generations are reclaimed', () async {
    final ownership = OfflineOwnershipService(
      store: MemoryOfflineStore(),
      files: const _NoopFiles(),
      scans: const _NoopScans(),
      reviews: const _NoopReviews(),
      databaseKeys: MemoryOfflineDatabaseKeyManager(),
    );

    for (var index = 0; index < 200; index += 1) {
      expect(
        (await ownership.apply(
          OfflineOwnershipIntent.permissionRefresh(accountId: '$index'),
        )).completed,
        isTrue,
      );
    }
    expect(ownership.debugGenerationMetadataEntryCount, 0);

    for (var index = 0; index < 50; index += 1) {
      final accountId = '$index';
      await ownership.apply(
        OfflineOwnershipIntent.tokenExpiry(accountId: accountId),
      );
      await ownership.apply(
        OfflineOwnershipIntent.reauthenticated(accountId: accountId),
      );
    }
    expect(ownership.debugGenerationMetadataEntryCount, 0);
  });

  test(
    'successful account switch is recoverable when the previous account logs in again',
    () async {
      final barrier = OfflineWriteBarrier();
      final rawStore = MemoryOfflineStore();
      final guardedStore = WriteBarrierOfflineStore(
        delegate: rawStore,
        barrier: barrier,
      );
      final ownership = _service(
        store: rawStore,
        scans: const _NoopScans(),
        keys: MemoryOfflineDatabaseKeyManager(),
        participants: [barrier],
      );
      expect(
        (await ownership.apply(
          const OfflineOwnershipIntent.accountSwitch(
            previousAccountId: '7',
            currentAccountId: '8',
          ),
        )).completed,
        isTrue,
      );
      await ownership.apply(
        const OfflineOwnershipIntent.logout(accountId: '8'),
      );
      final storage = _SessionStorage();
      final repository = CachedAuthRepository(
        delegate: _PendingAuthRepository(storage),
        store: guardedStore,
        tokenStorage: storage,
        accountStorage: storage,
        revocationStorage: storage,
        onSessionRevoked: () {},
        ownershipCoordinator: ownership,
      );

      final result = await repository.login(
        username: 'alice',
        password: 'secret',
      );

      expect(result, isA<Success<AuthSession>>());
      expect(ownership.canAccessOfflineData('7'), isTrue);
      await guardedStore.saveDraft(
        DocumentDraft(
          id: 'after-account-switch-return',
          accountId: '7',
          warehouseId: 1,
          payload: const {},
          createdAt: DateTime.utc(2026, 7, 14),
          updatedAt: DateTime.utc(2026, 7, 14),
        ),
      );
      expect((await rawStore.inspectAccount('7')).drafts, 1);
    },
  );

  test(
    'failed account-switch cleanup remains blocked on reauthentication',
    () async {
      final barrier = OfflineWriteBarrier();
      final rawStore = MemoryOfflineStore();
      final guardedStore = WriteBarrierOfflineStore(
        delegate: rawStore,
        barrier: barrier,
      );
      final files = _FailingOwnedFiles()..failNextClearAccount = true;
      final ownership = OfflineOwnershipService(
        store: rawStore,
        files: files,
        scans: const _NoopScans(),
        reviews: const _NoopReviews(),
        databaseKeys: MemoryOfflineDatabaseKeyManager(),
        mutationParticipants: [barrier],
      );
      expect(
        (await ownership.apply(
          const OfflineOwnershipIntent.accountSwitch(
            previousAccountId: '7',
            currentAccountId: '8',
          ),
        )).completed,
        isFalse,
      );

      await ownership.apply(
        const OfflineOwnershipIntent.reauthenticated(accountId: '7'),
      );

      expect(ownership.canAccessOfflineData('7'), isFalse);
      await expectLater(
        guardedStore.saveDraft(
          DocumentDraft(
            id: 'still-blocked',
            accountId: '7',
            warehouseId: 1,
            payload: const {},
            createdAt: DateTime.utc(2026, 7, 14),
            updatedAt: DateTime.utc(2026, 7, 14),
          ),
        ),
        throwsA(isA<OfflineWriteBlockedException>()),
      );
    },
  );

  test(
    'failed revocation retry cannot release a retained barrier through reauthentication',
    () async {
      final barrier = OfflineWriteBarrier();
      final rawStore = MemoryOfflineStore();
      final store = WriteBarrierOfflineStore(
        delegate: rawStore,
        barrier: barrier,
      );
      final files = _FailingOwnedFiles();
      final ownership = OfflineOwnershipService(
        store: rawStore,
        files: files,
        scans: const _NoopScans(),
        reviews: const _NoopReviews(),
        databaseKeys: MemoryOfflineDatabaseKeyManager(),
        mutationParticipants: [barrier],
      );
      final now = DateTime.utc(2026, 7, 13);
      final draft = DocumentDraft(
        id: 'after-revocation',
        accountId: '7',
        warehouseId: 1,
        payload: const {},
        createdAt: now,
        updatedAt: now,
      );
      expect(
        (await ownership.apply(
          const OfflineOwnershipIntent.revocation(accountId: '7'),
        )).completed,
        isTrue,
      );
      files.failNextClearAll = true;
      expect(
        (await ownership.apply(
          const OfflineOwnershipIntent.revocation(accountId: '7'),
        )).completed,
        isFalse,
      );

      await ownership.apply(
        const OfflineOwnershipIntent.reauthenticated(accountId: '7'),
      );

      await expectLater(
        store.saveDraft(draft),
        throwsA(isA<OfflineWriteBlockedException>()),
      );

      expect(
        (await ownership.apply(
          const OfflineOwnershipIntent.revocation(accountId: '7'),
        )).completed,
        isTrue,
      );
      await ownership.apply(
        const OfflineOwnershipIntent.reauthenticated(accountId: '7'),
      );
      await store.saveDraft(draft);
      expect((await rawStore.inspectAccount('7')).drafts, 1);
    },
  );

  test(
    'volatile revocation becomes durable before cleanup and survives a process restart',
    () async {
      final firstBarrier = OfflineWriteBarrier();
      final firstRawStore = MemoryOfflineStore();
      final firstStore = WriteBarrierOfflineStore(
        delegate: firstRawStore,
        barrier: firstBarrier,
      );
      final firstFiles = _FailingOwnedFiles()..failNextClearAll = true;
      final firstKeys = MemoryOfflineDatabaseKeyManager();
      final firstOwnership = OfflineOwnershipService(
        store: firstRawStore,
        files: firstFiles,
        scans: const _NoopScans(),
        reviews: const _NoopReviews(),
        databaseKeys: firstKeys,
        mutationParticipants: [firstBarrier],
      );
      final storage = _SessionStorage()
        ..token = 'revoked-token'
        ..accountId = '7'
        ..pendingMarkerWriteFailuresRemaining = 1;
      final firstDelegate = _PendingAuthRepository(storage);
      final firstRepository = CachedAuthRepository(
        delegate: firstDelegate,
        store: firstStore,
        tokenStorage: storage,
        accountStorage: storage,
        revocationStorage: storage,
        onSessionRevoked: () {},
        ownershipCoordinator: firstOwnership,
      );

      final initialFailure = await firstRepository.restoreSession();

      expect(initialFailure, isA<FailureResult<AuthSession?>>());
      expect(storage.pendingRevocationAccountId, isNull);
      expect(storage.token, isNull);
      expect(storage.accountId, isNull);
      expect(firstFiles.clearAllCalls, 1);
      expect(firstKeys.generation, 0);

      firstFiles.failNextClearAll = true;

      final volatileRetry = await firstRepository.login(
        username: 'alice',
        password: 'secret',
      );

      expect(volatileRetry, isA<FailureResult<AuthSession>>());
      expect(firstDelegate.loginCalls, 0);
      expect(firstFiles.clearAllCalls, 2);
      expect(storage.token, isNull);
      expect(storage.pendingRevocationAccountId, '7');
      expect(firstKeys.generation, 0);
      await expectLater(
        firstStore.saveDraft(
          DocumentDraft(
            id: 'blocked',
            accountId: '7',
            warehouseId: 1,
            payload: const {},
            createdAt: DateTime.utc(2026, 7, 13),
            updatedAt: DateTime.utc(2026, 7, 13),
          ),
        ),
        throwsA(isA<OfflineWriteBlockedException>()),
      );

      final restartedBarrier = OfflineWriteBarrier();
      final restartedRawStore = MemoryOfflineStore();
      final restartedStore = WriteBarrierOfflineStore(
        delegate: restartedRawStore,
        barrier: restartedBarrier,
      );
      final restartedFiles = _FailingOwnedFiles()..failNextClearAll = true;
      final restartedKeys = MemoryOfflineDatabaseKeyManager();
      final restartedOwnership = OfflineOwnershipService(
        store: restartedRawStore,
        files: restartedFiles,
        scans: const _NoopScans(),
        reviews: const _NoopReviews(),
        databaseKeys: restartedKeys,
        mutationParticipants: [restartedBarrier],
      );
      final restartedDelegate = _PendingAuthRepository(storage);
      final restartedRepository = CachedAuthRepository(
        delegate: restartedDelegate,
        store: restartedStore,
        tokenStorage: storage,
        accountStorage: storage,
        revocationStorage: storage,
        onSessionRevoked: () {},
        ownershipCoordinator: restartedOwnership,
      );

      final restartedFailure = await restartedRepository.login(
        username: 'alice',
        password: 'secret',
      );

      expect(restartedFailure, isA<FailureResult<AuthSession>>());
      expect(restartedDelegate.loginCalls, 0);
      expect(storage.pendingRevocationAccountId, '7');
      expect(restartedKeys.generation, 0);

      final successfulLogin = await restartedRepository.login(
        username: 'alice',
        password: 'secret',
      );

      expect(
        successfulLogin,
        isA<Success<AuthSession>>(),
        reason: switch (successfulLogin) {
          FailureResult<AuthSession>(failure: final failure) =>
            '${failure.message}: ${failure.cause}',
          _ => null,
        },
      );
      expect(restartedDelegate.loginCalls, 1);
      expect(storage.token, 'new-token');
      expect(storage.pendingRevocationAccountId, isNull);
      expect(restartedKeys.generation, 1);
      expect(restartedOwnership.canAccessOfflineData('7'), isTrue);
    },
  );

  test('repeated volatile marker failures block cleanup and login', () async {
    final barrier = OfflineWriteBarrier();
    final rawStore = MemoryOfflineStore();
    final files = _FailingOwnedFiles();
    final keys = MemoryOfflineDatabaseKeyManager();
    final ownership = OfflineOwnershipService(
      store: rawStore,
      files: files,
      scans: const _NoopScans(),
      reviews: const _NoopReviews(),
      databaseKeys: keys,
      mutationParticipants: [barrier],
    );
    final storage = _SessionStorage()
      ..token = 'revoked-token'
      ..accountId = '7'
      ..pendingMarkerWriteFailuresRemaining = 2;
    final delegate = _PendingAuthRepository(storage);
    final repository = CachedAuthRepository(
      delegate: delegate,
      store: WriteBarrierOfflineStore(delegate: rawStore, barrier: barrier),
      tokenStorage: storage,
      accountStorage: storage,
      revocationStorage: storage,
      onSessionRevoked: () {},
      ownershipCoordinator: ownership,
    );

    expect(
      await repository.restoreSession(),
      isA<FailureResult<AuthSession?>>(),
    );
    expect(
      await repository.login(username: 'alice', password: 'secret'),
      isA<FailureResult<AuthSession>>(),
    );

    expect(storage.pendingMarkerWriteCalls, 2);
    expect(storage.pendingRevocationAccountId, isNull);
    expect(storage.token, isNull);
    expect(storage.accountId, isNull);
    expect(files.clearAllCalls, 2);
    expect(keys.generation, 2);
    expect(delegate.loginCalls, 0);
  });

  test(
    'durable pending revocation is drained before login after repository restart',
    () async {
      final barrier = OfflineWriteBarrier();
      final rawStore = MemoryOfflineStore();
      final store = WriteBarrierOfflineStore(
        delegate: rawStore,
        barrier: barrier,
      );
      final files = _BlockingOwnedFiles();
      final keys = MemoryOfflineDatabaseKeyManager();
      final ownership = OfflineOwnershipService(
        store: rawStore,
        files: files,
        scans: const _NoopScans(),
        reviews: const _NoopReviews(),
        databaseKeys: keys,
        mutationParticipants: [barrier],
      );
      final storage = _SessionStorage()
        ..token = 'revoked-token'
        ..accountId = '7'
        ..pendingRevocationAccountId = '7';
      final delegate = _PendingAuthRepository(storage);
      final repository = CachedAuthRepository(
        delegate: delegate,
        store: store,
        tokenStorage: storage,
        accountStorage: storage,
        revocationStorage: storage,
        onSessionRevoked: () {},
        ownershipCoordinator: ownership,
      );

      final login = repository.login(username: 'alice', password: 'secret');
      for (var index = 0; index < 5; index += 1) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(files.clearStarted.isCompleted, isTrue);
      expect(delegate.loginCalls, 0);
      expect(storage.token, isNull);
      expect(keys.generation, 0);
      await expectLater(
        store.saveDraft(
          DocumentDraft(
            id: 'blocked-during-restart',
            accountId: '7',
            warehouseId: 1,
            payload: const {},
            createdAt: DateTime.utc(2026, 7, 13),
            updatedAt: DateTime.utc(2026, 7, 13),
          ),
        ),
        throwsA(isA<OfflineWriteBlockedException>()),
      );

      files.releaseClear.complete();
      expect(await login, isA<Success<AuthSession>>());
      expect(delegate.loginCalls, 1);
      expect(storage.token, 'new-token');
      expect(storage.pendingRevocationAccountId, isNull);
      expect(keys.generation, 1);
      expect(ownership.canAccessOfflineData('7'), isTrue);
    },
  );

  test(
    'blocked scan persistence drains before revocation and cannot recreate a cleared session',
    () async {
      final barrier = OfflineWriteBarrier();
      final storage = _BlockedScanStorage();
      final sessions = ScanSessionStore(
        storage: storage,
        writeBarrier: barrier,
      );
      final keys = MemoryOfflineDatabaseKeyManager();
      final ownership = _service(
        store: MemoryOfflineStore(),
        scans: sessions,
        keys: keys,
        participants: [barrier],
      );
      final firstWrite = sessions.save(
        userId: '7',
        warehouseId: 1,
        session: const ScanSessionSnapshot(mode: ScanMode.batch, lines: []),
      );
      await storage.writeStarted.future;

      final revocation = ownership.apply(
        const OfflineOwnershipIntent.revocation(accountId: '7'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(keys.generation, 0);
      expect(storage.deleteCalls, 0);
      await expectLater(
        sessions.save(
          userId: '7',
          warehouseId: 2,
          session: const ScanSessionSnapshot(mode: ScanMode.batch, lines: []),
        ),
        throwsA(isA<OfflineWriteBlockedException>()),
      );
      final lookup = ScanLookupCache(storage: storage, writeBarrier: barrier);
      await expectLater(
        lookup.put(
          userId: '7',
          warehouseId: 1,
          barcode: 'SKU-1',
          item: _inventoryItem,
        ),
        throwsA(isA<OfflineWriteBlockedException>()),
      );

      storage.releaseWrite.complete();
      await firstWrite;
      expect(
        (await storage.keys(prefix: 'rims.scanner.session.v1.')),
        isNotEmpty,
      );
      final report = await revocation;

      expect(report.completed, isTrue);
      expect(keys.generation, 1);
      expect((await storage.keys(prefix: 'rims.scanner.session.v1.')), isEmpty);
    },
  );

  test(
    'logout drains staged file persistence before cleanup and rejects a second staging write',
    () async {
      final root = await Directory.systemTemp.createTemp('ownership_barrier_');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}${Platform.pathSeparator}source.pdf');
      await source.writeAsBytes(Uint8List.fromList([1, 2, 3]));
      final barrier = OfflineWriteBarrier();
      final copyStarted = Completer<void>();
      final releaseCopy = Completer<void>();
      var nextId = 0;
      final staging = FileAttachmentStagingStore(
        rootDirectory: () async => root,
        idFactory: () => 'request-${++nextId}',
        writeBarrier: barrier,
        copyFile: (sourcePath, destinationPath) async {
          if (!copyStarted.isCompleted) copyStarted.complete();
          await releaseCopy.future;
          await File(sourcePath).copy(destinationPath);
        },
        thumbnailBuilder: (_, _) async => null,
      );
      final ownership = OfflineOwnershipService(
        store: MemoryOfflineStore(),
        files: staging,
        scans: const _NoopScans(),
        reviews: const _NoopReviews(),
        databaseKeys: MemoryOfflineDatabaseKeyManager(),
        mutationParticipants: [barrier],
      );
      final selection = SelectedAttachmentSource(
        path: source.path,
        originalName: 'source.pdf',
        mimeType: 'application/pdf',
        fileSize: 3,
      );
      final firstStage = staging.stage(
        userId: '7',
        binding: AttachmentBinding.documentDraft('draft-1'),
        selection: selection,
        existingCount: 0,
      );
      await copyStarted.future;

      final logout = ownership.apply(
        const OfflineOwnershipIntent.logout(accountId: '7'),
      );
      await Future<void>.delayed(Duration.zero);

      final blockedStage = staging.stage(
        userId: '7',
        binding: AttachmentBinding.documentDraft('draft-2'),
        selection: selection,
        existingCount: 0,
      );
      final blockedDownload = staging.saveDownload(
        userId: '7',
        originalName: 'blocked.pdf',
        bytes: Uint8List.fromList([4, 5, 6]),
      );
      final blockedCleanup = staging.cleanupStale(
        userId: '7',
        maxAge: Duration.zero,
      );
      releaseCopy.complete();
      await expectLater(
        blockedStage.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw StateError('blocked stage did not settle'),
        ),
        throwsA(isA<OfflineWriteBlockedException>()),
      );
      await expectLater(
        blockedDownload,
        throwsA(isA<OfflineWriteBlockedException>()),
      );
      await expectLater(
        blockedCleanup,
        throwsA(isA<OfflineWriteBlockedException>()),
      );
      expect(
        (await firstStage.timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw StateError('first stage did not settle'),
        )).when(success: (_) => true, failure: (_) => false),
        isTrue,
      );
      final report = await logout.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('logout did not settle'),
      );

      expect(report.completed, isTrue);
      expect((await staging.inspectAccount('7')).stagedTransfers, 0);
    },
  );
}

OfflineOwnershipService _service({
  required OfflineOwnershipStore store,
  required OfflineOwnedScanStore scans,
  required OfflineDatabaseKeyManager keys,
  required List<OfflineMutationParticipant> participants,
}) {
  return OfflineOwnershipService(
    store: store,
    files: const _NoopFiles(),
    scans: scans,
    reviews: const _NoopReviews(),
    databaseKeys: keys,
    mutationParticipants: participants,
  );
}

OfflineOwnershipIntent _intentFor(OfflineOwnershipReason reason) =>
    switch (reason) {
      OfflineOwnershipReason.accountSwitch =>
        const OfflineOwnershipIntent.accountSwitch(
          previousAccountId: '7',
          currentAccountId: '8',
        ),
      OfflineOwnershipReason.revocation =>
        const OfflineOwnershipIntent.revocation(accountId: '7'),
      OfflineOwnershipReason.permissionRefresh =>
        const OfflineOwnershipIntent.permissionRefresh(accountId: '7'),
      OfflineOwnershipReason.warehouseSwitch =>
        const OfflineOwnershipIntent.warehouseSwitch(
          accountId: '7',
          previousWarehouseId: 1,
          currentWarehouseId: 2,
        ),
      OfflineOwnershipReason.tokenExpiry =>
        const OfflineOwnershipIntent.tokenExpiry(accountId: '7'),
      _ => throw ArgumentError.value(reason),
    };

final class _ControlledOwnershipAttempt {
  _ControlledOwnershipAttempt._({required this.fails, required bool blocked}) {
    if (!blocked) release.complete();
  }

  factory _ControlledOwnershipAttempt.blocked({bool fails = false}) =>
      _ControlledOwnershipAttempt._(fails: fails, blocked: true);
  factory _ControlledOwnershipAttempt.failed() =>
      _ControlledOwnershipAttempt._(fails: true, blocked: false);
  factory _ControlledOwnershipAttempt.successful() =>
      _ControlledOwnershipAttempt._(fails: false, blocked: false);

  final bool fails;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
}

final class _AttemptControlledOwnershipStore implements OfflineOwnershipStore {
  _AttemptControlledOwnershipStore(this.reason, this.attempts);

  final OfflineOwnershipReason reason;
  final List<_ControlledOwnershipAttempt> attempts;
  int _callCount = 0;
  int get callCount => _callCount;

  Future<void> _run(OfflineOwnershipReason invokedReason) async {
    if (invokedReason != reason) return;
    final attempt = attempts[_callCount++];
    attempt.started.complete();
    await attempt.release.future;
    if (attempt.fails) throw StateError('${reason.name} failed');
  }

  @override
  Future<void> clearAccountCache(String accountId) async {}

  @override
  Future<void> clearAccountOfflineWork(String accountId) async {}

  @override
  Future<void> clearAllSensitiveData() =>
      _run(OfflineOwnershipReason.revocation);

  @override
  Future<void> clearOwnedAccount(
    String accountId, {
    required bool preserveDrafts,
  }) => _run(OfflineOwnershipReason.accountSwitch);

  @override
  Future<void> discardSessionProjection(String accountId) async {}

  @override
  Future<void> invalidatePermissionScopedCache(String accountId) =>
      _run(OfflineOwnershipReason.permissionRefresh);

  @override
  Future<void> invalidateWarehouseCache({
    required String accountId,
    required int warehouseId,
  }) => _run(OfflineOwnershipReason.warehouseSwitch);

  @override
  Future<OfflineStoreOwnershipSnapshot> inspectAccount(
    String accountId,
  ) async => const OfflineStoreOwnershipSnapshot();
}

final class _BlockedScanStorage implements AsyncScanStorage {
  final Map<String, String> values = {};
  final Completer<void> writeStarted = Completer<void>();
  final Completer<void> releaseWrite = Completer<void>();
  int deleteCalls = 0;

  @override
  Future<void> delete(String key) async {
    deleteCalls += 1;
    values.remove(key);
  }

  @override
  Future<Set<String>> keys({required String prefix}) async =>
      values.keys.where((key) => key.startsWith(prefix)).toSet();

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    await releaseWrite.future;
    values[key] = value;
  }
}

final class _ThrowingMutationParticipant implements OfflineMutationParticipant {
  _ThrowingMutationParticipant({
    this.throwOnAcquire = false,
    this.throwOnWait = false,
    this.throwOnAcquireCall,
  });

  bool throwOnAcquire;
  bool throwOnWait;
  int? throwOnAcquireCall;
  int? throwOnReleaseCall;
  int acquireCalls = 0;
  int releaseCalls = 0;
  int activeBlocks = 0;

  @override
  OfflineMutationBlock blockMutations(OfflineMutationScope scope) {
    acquireCalls += 1;
    if (throwOnAcquire || acquireCalls == throwOnAcquireCall) {
      throw StateError('block acquisition failed');
    }
    activeBlocks += 1;
    return _ThrowingMutationBlock(this);
  }
}

final class _ThrowingMutationBlock implements OfflineMutationBlock {
  _ThrowingMutationBlock(this.participant);

  final _ThrowingMutationParticipant participant;
  bool released = false;

  @override
  final Object blockId = Object();

  @override
  void release() {
    if (released) return;
    participant.releaseCalls += 1;
    if (participant.releaseCalls == participant.throwOnReleaseCall) {
      throw StateError('block release failed');
    }
    released = true;
    participant.activeBlocks -= 1;
  }

  @override
  Future<void> waitForQuiescence() async {
    if (participant.throwOnWait) {
      throw StateError('quiescence failed');
    }
  }
}

CacheRecord _ownedCacheRecord(String accountId, String entityKey) {
  final now = DateTime.utc(2026, 7, 14);
  return CacheRecord(
    key: CacheKey(
      accountId: accountId,
      namespace: 'auth.session',
      entityKey: entityKey,
    ),
    payload: const {'value': 'owned'},
    schemaVersion: 1,
    fetchedAt: now,
    expiresAt: now.add(const Duration(days: 1)),
  );
}

final class _NoopFiles implements OfflineOwnedFileStore {
  const _NoopFiles();

  @override
  Future<void> clearAccountFiles(
    String accountId, {
    required Set<String> retainStagedRequestIds,
  }) async {}

  @override
  Future<void> clearAllFiles() async {}

  @override
  Future<void> clearDownloads(String accountId) async {}

  @override
  Future<void> clearStagedTransfers(String accountId) async {}

  @override
  Future<OfflineFileOwnershipSnapshot> inspectAccount(String accountId) async =>
      const OfflineFileOwnershipSnapshot();
}

final class _FailingOwnedFiles implements OfflineOwnedFileStore {
  bool failNextClearAccount = false;
  bool failNextClearAll = false;
  int clearAllCalls = 0;

  @override
  Future<void> clearAccountFiles(
    String accountId, {
    required Set<String> retainStagedRequestIds,
  }) async {
    if (!failNextClearAccount) return;
    failNextClearAccount = false;
    throw StateError('account file cleanup failed');
  }

  @override
  Future<void> clearAllFiles() async {
    clearAllCalls += 1;
    if (!failNextClearAll) return;
    failNextClearAll = false;
    throw StateError('file cleanup failed');
  }

  @override
  Future<void> clearDownloads(String accountId) async {}

  @override
  Future<void> clearStagedTransfers(String accountId) async {}

  @override
  Future<OfflineFileOwnershipSnapshot> inspectAccount(String accountId) async =>
      const OfflineFileOwnershipSnapshot();
}

final class _BlockingOwnedFiles implements OfflineOwnedFileStore {
  final Completer<void> clearStarted = Completer<void>();
  final Completer<void> releaseClear = Completer<void>();

  @override
  Future<void> clearAccountFiles(
    String accountId, {
    required Set<String> retainStagedRequestIds,
  }) async {}

  @override
  Future<void> clearAllFiles() async {
    clearStarted.complete();
    await releaseClear.future;
  }

  @override
  Future<void> clearDownloads(String accountId) async {}

  @override
  Future<void> clearStagedTransfers(String accountId) async {}

  @override
  Future<OfflineFileOwnershipSnapshot> inspectAccount(String accountId) async =>
      const OfflineFileOwnershipSnapshot();
}

final class _NoopScans implements OfflineOwnedScanStore {
  const _NoopScans();

  @override
  Future<void> clearAll() async {}

  @override
  Future<void> clearForAccount(String accountId) async {}

  @override
  Future<int> countForAccount(String accountId) async => 0;
}

final class _NoopReviews implements OfflineReviewInvalidator {
  const _NoopReviews();

  @override
  Future<void> invalidate({
    required String accountId,
    int? warehouseId,
  }) async {}
}

final class _SessionStorage
    implements
        TokenStorage,
        AuthTokenTransactionStorage,
        AuthenticatedAccountStorage,
        AuthenticatedAccountTransactionStorage,
        PendingRevocationStorage {
  String? token;
  String? tokenOwnerId;
  int latestAttemptVersion = 0;
  int? tokenAttemptVersion;
  bool tokenCommitted = true;
  String? accountId;
  String? accountOwnerId;
  int? accountAttemptVersion;
  String? pendingRevocationAccountId;
  int pendingMarkerWriteFailuresRemaining = 0;
  int pendingMarkerWriteCalls = 0;

  @override
  Future<void> clearAccessToken() async {
    token = null;
    tokenOwnerId = null;
    tokenAttemptVersion = null;
    tokenCommitted = false;
  }

  @override
  Future<String?> readAccessToken() async => tokenCommitted ? token : null;

  @override
  Future<void> saveAccessToken(String token) async {
    this.token = token;
    tokenOwnerId = null;
    tokenAttemptVersion = null;
    tokenCommitted = true;
  }

  @override
  Future<int> beginAccessTokenAttempt(String ownerId) async =>
      ++latestAttemptVersion;

  @override
  Future<bool> savePendingAccessTokenForOwner({
    required String token,
    required String ownerId,
    required int attemptVersion,
  }) async {
    if (attemptVersion != latestAttemptVersion) return false;
    this.token = token;
    tokenOwnerId = ownerId;
    tokenAttemptVersion = attemptVersion;
    tokenCommitted = false;
    return true;
  }

  @override
  Future<bool> commitAccessTokenForOwner(
    String ownerId, {
    required int attemptVersion,
  }) async {
    if (tokenOwnerId != ownerId ||
        tokenAttemptVersion != attemptVersion ||
        latestAttemptVersion != attemptVersion) {
      return false;
    }
    tokenCommitted = true;
    return true;
  }

  @override
  Future<bool> clearAccessTokenForOwner(
    String ownerId, {
    required int attemptVersion,
  }) async {
    if (tokenOwnerId != ownerId || tokenAttemptVersion != attemptVersion) {
      return false;
    }
    await clearAccessToken();
    return true;
  }

  @override
  Future<bool> clearPendingAccessToken() async {
    if (token == null || tokenCommitted) return false;
    await clearAccessToken();
    return true;
  }

  @override
  Future<void> clearAuthenticatedAccountId() async {
    accountId = null;
    accountOwnerId = null;
    accountAttemptVersion = null;
  }

  @override
  Future<String?> readAuthenticatedAccountId() async => accountId;

  @override
  Future<void> saveAuthenticatedAccountId(String accountId) async {
    this.accountId = accountId;
    accountOwnerId = null;
    accountAttemptVersion = null;
  }

  @override
  Future<bool> saveAuthenticatedAccountProjection({
    required String accountId,
    required String ownerId,
    required int attemptVersion,
  }) async {
    if ((accountAttemptVersion ?? -1) > attemptVersion) return false;
    this.accountId = accountId;
    accountOwnerId = ownerId;
    accountAttemptVersion = attemptVersion;
    return true;
  }

  @override
  Future<bool> clearAuthenticatedAccountProjection({
    required String ownerId,
    required int attemptVersion,
  }) async {
    if (accountOwnerId != ownerId || accountAttemptVersion != attemptVersion) {
      return false;
    }
    await clearAuthenticatedAccountId();
    return true;
  }

  @override
  Future<void> clearPendingRevocationAccountId() async {
    pendingRevocationAccountId = null;
  }

  @override
  Future<String?> readPendingRevocationAccountId() async =>
      pendingRevocationAccountId;

  @override
  Future<void> savePendingRevocationAccountId(String accountId) async {
    pendingMarkerWriteCalls += 1;
    if (pendingMarkerWriteFailuresRemaining > 0) {
      pendingMarkerWriteFailuresRemaining -= 1;
      throw StateError('pending marker write failed');
    }
    pendingRevocationAccountId = accountId;
  }
}

final class _PendingAuthRepository
    implements
        AuthRepository,
        TransactionalAuthRepository,
        ProvisionalTransactionalAuthRepository {
  _PendingAuthRepository(this.storage);

  final _SessionStorage storage;
  int loginCalls = 0;

  @override
  Object get tokenTransactionStorageIdentity => storage;

  @override
  Future<Result<AuthSession>> login({
    required String username,
    required String password,
  }) async {
    final prepared = await prepareLogin(username: username, password: password);
    return switch (prepared) {
      Success<AuthSessionTransaction>(data: final transaction) => () async {
        final committed = await transaction.commit();
        return switch (committed) {
          Success<void>() => Success(transaction.session),
          FailureResult<void>(failure: final failure) =>
            FailureResult<AuthSession>(failure),
        };
      }(),
      FailureResult<AuthSessionTransaction>(failure: final failure) =>
        FailureResult<AuthSession>(failure),
    };
  }

  @override
  Future<Result<AuthSessionTransaction>> prepareLogin({
    required String username,
    required String password,
  }) async {
    loginCalls += 1;
    final ownerId = 'pending-owner-$loginCalls';
    final attemptVersion = await storage.beginAccessTokenAttempt(ownerId);
    final saved = await storage.savePendingAccessTokenForOwner(
      token: 'new-token',
      ownerId: ownerId,
      attemptVersion: attemptVersion,
    );
    if (!saved) {
      return const FailureResult(
        LocalStorageFailure(message: 'credential superseded'),
      );
    }
    return Success(
      _PendingAuthSessionTransaction(
        storage: storage,
        ownerId: ownerId,
        attemptVersion: attemptVersion,
      ),
    );
  }

  @override
  Future<void> logout() => storage.clearAccessToken();

  @override
  Future<Result<AuthSession?>> restoreSession() async =>
      const FailureResult(AuthorizationFailure(statusCode: 403));

  @override
  Future<Result<Warehouse>> switchCurrentWarehouse(Warehouse warehouse) async =>
      Success(warehouse);
}

final class _PendingAuthSessionTransaction
    implements AuthSessionTransaction, ProvisionalAuthSessionTransaction {
  const _PendingAuthSessionTransaction({
    required this.storage,
    required this.ownerId,
    required this.attemptVersion,
  });

  final _SessionStorage storage;
  final String ownerId;
  final int attemptVersion;

  @override
  AuthSession get session => _authSession;

  @override
  String get transactionOwnerId => ownerId;

  @override
  int get transactionAttemptVersion => attemptVersion;

  @override
  Future<Result<void>> abort() async {
    await storage.clearAccessTokenForOwner(
      ownerId,
      attemptVersion: attemptVersion,
    );
    return const Success(null);
  }

  @override
  Future<Result<void>> commit() async =>
      await storage.commitAccessTokenForOwner(
        ownerId,
        attemptVersion: attemptVersion,
      )
      ? const Success(null)
      : const FailureResult(
          LocalStorageFailure(message: 'credential superseded'),
        );
}

const _authWarehouse = Warehouse(
  id: 1,
  code: 'SH',
  name: 'Shanghai',
  isDefault: true,
);

const _authSession = AuthSession(
  accessToken: 'new-token',
  user: AppUser(
    id: 7,
    username: 'alice',
    realName: 'Alice',
    roleCode: 'user',
    roleName: 'User',
  ),
  currentWarehouse: _authWarehouse,
  warehouses: [_authWarehouse],
);

const _inventoryItem = InventoryItem(
  id: 1,
  productId: 1,
  productName: 'Product',
  sku: 'SKU-1',
  availableQuantity: 1,
  stockQuantity: 1,
  statusLabel: 'available',
  imageUrl: '',
);
