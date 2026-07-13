import 'dart:async';

enum OfflineOwnershipReason {
  logout,
  accountSwitch,
  warehouseSwitch,
  permissionRefresh,
  tokenExpiry,
  reauthenticated,
  revocation,
  invalidSessionProjection,
}

enum DraftRetentionChoice { delete, retainLocally }

enum OfflineClearCommand { cache, offlineWork }

enum OfflineOwnershipStep {
  mutationQuiescence,
  store,
  files,
  scanSessions,
  reviewedSyncAuthority,
  databaseKey,
  preview,
}

final class OfflineOwnershipIntent {
  const OfflineOwnershipIntent._({
    required this.reason,
    required this.accountId,
    this.currentAccountId,
    this.previousWarehouseId,
    this.currentWarehouseId,
    this.draftRetention = DraftRetentionChoice.delete,
  });

  const OfflineOwnershipIntent.logout({
    required String accountId,
    DraftRetentionChoice draftRetention = DraftRetentionChoice.delete,
  }) : this._(
         reason: OfflineOwnershipReason.logout,
         accountId: accountId,
         draftRetention: draftRetention,
       );

  const OfflineOwnershipIntent.accountSwitch({
    required String previousAccountId,
    required String currentAccountId,
  }) : this._(
         reason: OfflineOwnershipReason.accountSwitch,
         accountId: previousAccountId,
         currentAccountId: currentAccountId,
       );

  const OfflineOwnershipIntent.warehouseSwitch({
    required String accountId,
    required int previousWarehouseId,
    required int currentWarehouseId,
  }) : this._(
         reason: OfflineOwnershipReason.warehouseSwitch,
         accountId: accountId,
         previousWarehouseId: previousWarehouseId,
         currentWarehouseId: currentWarehouseId,
       );

  const OfflineOwnershipIntent.permissionRefresh({required String accountId})
    : this._(
        reason: OfflineOwnershipReason.permissionRefresh,
        accountId: accountId,
      );

  const OfflineOwnershipIntent.tokenExpiry({required String accountId})
    : this._(reason: OfflineOwnershipReason.tokenExpiry, accountId: accountId);

  const OfflineOwnershipIntent.reauthenticated({required String accountId})
    : this._(
        reason: OfflineOwnershipReason.reauthenticated,
        accountId: accountId,
      );

  const OfflineOwnershipIntent.revocation({required String accountId})
    : this._(reason: OfflineOwnershipReason.revocation, accountId: accountId);

  const OfflineOwnershipIntent.invalidSessionProjection({
    required String accountId,
  }) : this._(
         reason: OfflineOwnershipReason.invalidSessionProjection,
         accountId: accountId,
       );

  final OfflineOwnershipReason reason;
  final String accountId;
  final String? currentAccountId;
  final int? previousWarehouseId;
  final int? currentWarehouseId;
  final DraftRetentionChoice draftRetention;
}

final class OfflineStoreOwnershipSnapshot {
  const OfflineStoreOwnershipSnapshot({
    this.cacheEntries = 0,
    this.drafts = 0,
    this.outboxOperations = 0,
    this.draftAttachmentRequestIds = const {},
    this.contentIdentities = const {},
  });

  final int cacheEntries;
  final int drafts;
  final int outboxOperations;
  final Set<String> draftAttachmentRequestIds;
  final Set<String> contentIdentities;
}

final class OfflineFileOwnershipSnapshot {
  const OfflineFileOwnershipSnapshot({
    this.stagedTransfers = 0,
    this.downloads = 0,
    this.contentIdentities = const {},
  });

  final int stagedTransfers;
  final int downloads;
  final Set<String> contentIdentities;
}

final class OfflineOwnershipCounts {
  const OfflineOwnershipCounts({
    this.cacheEntries = 0,
    this.drafts = 0,
    this.outboxOperations = 0,
    this.stagedTransfers = 0,
    this.downloads = 0,
    this.scanSessions = 0,
  });

  final int cacheEntries;
  final int drafts;
  final int outboxOperations;
  final int stagedTransfers;
  final int downloads;
  final int scanSessions;

  @override
  bool operator ==(Object other) =>
      other is OfflineOwnershipCounts &&
      cacheEntries == other.cacheEntries &&
      drafts == other.drafts &&
      outboxOperations == other.outboxOperations &&
      stagedTransfers == other.stagedTransfers &&
      downloads == other.downloads &&
      scanSessions == other.scanSessions;

  @override
  int get hashCode => Object.hash(
    cacheEntries,
    drafts,
    outboxOperations,
    stagedTransfers,
    downloads,
    scanSessions,
  );
}

final class OfflineClearPreview {
  const OfflineClearPreview({
    required this.accountId,
    required this.command,
    required this.counts,
    required this.sequence,
    this.contentRevision = '',
  });

  final String accountId;
  final OfflineClearCommand command;
  final OfflineOwnershipCounts counts;
  final int sequence;
  final String contentRevision;
}

final class OfflineOwnershipFailure {
  const OfflineOwnershipFailure({
    required this.step,
    required this.message,
    this.cause,
  });

  final OfflineOwnershipStep step;
  final String message;
  final Object? cause;
}

final class OfflineOwnershipReport {
  OfflineOwnershipReport({
    required this.reason,
    required this.accountId,
    required this.executedCounts,
    required List<OfflineOwnershipFailure> failures,
    this.changedSincePreview = false,
    this.currentPreview,
    this.remainingCounts = const OfflineOwnershipCounts(),
  }) : failures = List.unmodifiable(failures);

  final OfflineOwnershipReason? reason;
  final String accountId;
  final OfflineOwnershipCounts executedCounts;
  final OfflineOwnershipCounts remainingCounts;
  final List<OfflineOwnershipFailure> failures;
  final bool changedSincePreview;
  final OfflineClearPreview? currentPreview;

  bool get requiresReconfirmation => currentPreview != null;

  bool get completed => failures.isEmpty && !requiresReconfirmation;
}

abstract interface class OfflineOwnershipStore {
  Future<OfflineStoreOwnershipSnapshot> inspectAccount(String accountId);

  Future<void> clearOwnedAccount(
    String accountId, {
    required bool preserveDrafts,
  });

  Future<void> clearAccountCache(String accountId);

  Future<void> clearAccountOfflineWork(String accountId);

  Future<void> invalidateWarehouseCache({
    required String accountId,
    required int warehouseId,
  });

  Future<void> invalidatePermissionScopedCache(String accountId);

  Future<void> discardSessionProjection(String accountId);

  Future<void> clearAllSensitiveData();
}

abstract interface class OfflineOwnedFileStore {
  Future<OfflineFileOwnershipSnapshot> inspectAccount(String accountId);

  Future<void> clearAccountFiles(
    String accountId, {
    required Set<String> retainStagedRequestIds,
  });

  Future<void> clearDownloads(String accountId);

  Future<void> clearStagedTransfers(String accountId);

  Future<void> clearAllFiles();
}

abstract interface class OfflineOwnedScanStore {
  Future<int> countForAccount(String accountId);

  Future<void> clearForAccount(String accountId);

  Future<void> clearAll();
}

abstract interface class OfflineScanOwnershipInspector {
  Future<Set<String>> contentIdentitiesForAccount(String accountId);
}

abstract interface class OfflineLookupOwnershipStore {
  Future<int> countLookupCacheForAccount(String accountId);

  Future<void> clearLookupCacheForAccount(String accountId);

  Future<void> clearLookupCacheForWarehouse(String accountId, int warehouseId);
}

abstract interface class OfflineReviewInvalidator {
  Future<void> invalidate({required String accountId, int? warehouseId});
}

abstract interface class OfflineDatabaseKeyManager {
  Future<void> rotateAfterRevocation();
}

final class OfflineMutationScope {
  const OfflineMutationScope.account(String accountId)
    : accountIds = const {},
      _accountId = accountId,
      allAccounts = false;

  const OfflineMutationScope.all()
    : accountIds = const {},
      _accountId = null,
      allAccounts = true;

  final Set<String> accountIds;
  final String? _accountId;
  final bool allAccounts;

  Set<String> get resolvedAccountIds =>
      _accountId == null ? accountIds : {_accountId};

  bool contains(String accountId) =>
      allAccounts || resolvedAccountIds.contains(accountId);
}

abstract interface class OfflineMutationBlock {
  Future<void> waitForQuiescence();

  void release();
}

abstract interface class OfflineMutationParticipant {
  OfflineMutationBlock blockMutations(OfflineMutationScope scope);
}

final class MemoryOfflineDatabaseKeyManager
    implements OfflineDatabaseKeyManager {
  int generation = 0;

  @override
  Future<void> rotateAfterRevocation() async {
    generation += 1;
  }
}

abstract interface class OfflineOwnershipCoordinator {
  Future<OfflineOwnershipReport> apply(OfflineOwnershipIntent intent);

  bool canSync(String accountId);

  bool canAccessOfflineData(String accountId);
}

final class OfflineOwnershipService implements OfflineOwnershipCoordinator {
  OfflineOwnershipService({
    required this.store,
    required this.files,
    required this.scans,
    required this.reviews,
    required this.databaseKeys,
    Iterable<OfflineMutationParticipant> mutationParticipants = const [],
  }) : _mutationParticipants = [...mutationParticipants];

  final OfflineOwnershipStore store;
  final OfflineOwnedFileStore files;
  final OfflineOwnedScanStore scans;
  final OfflineReviewInvalidator reviews;
  final OfflineDatabaseKeyManager databaseKeys;
  final List<OfflineMutationParticipant> _mutationParticipants;
  final Map<String, Map<_OwnershipBlockKey, Map<int, List<_ParticipantBlock>>>>
  _retainedMutationBlocks = {};

  final Map<String, Map<_OwnershipBlockKey, Set<int>>> _blockedReasons = {};
  final Set<String> _commandBlockedAccounts = {};
  final Map<String, Map<_OwnershipBlockKey, int>> _latestAttemptGenerations =
      {};
  final Map<String, Map<_OwnershipBlockKey, int>>
  _successfulAttemptGenerations = {};
  Future<void> _tail = Future<void>.value();
  int _previewSequence = 0;
  int _attemptGeneration = 0;

  void attachMutationParticipant(OfflineMutationParticipant participant) {
    if (_mutationParticipants.any(
      (current) => identical(current, participant),
    )) {
      return;
    }
    _mutationParticipants.add(participant);
  }

  @override
  bool canSync(String accountId) => !_isBlocked(accountId);

  @override
  bool canAccessOfflineData(String accountId) => !_isBlocked(accountId);

  int get debugGenerationMetadataEntryCount {
    int countNested(Map<String, Map<_OwnershipBlockKey, int>> values) =>
        values.values.fold(0, (sum, entries) => sum + entries.length);
    final retained = _retainedMutationBlocks.values.fold<int>(
      0,
      (sum, reasons) =>
          sum +
          reasons.values.fold(0, (inner, entries) => inner + entries.length),
    );
    final blocked = _blockedReasons.values.fold<int>(
      0,
      (sum, reasons) =>
          sum +
          reasons.values.fold(0, (inner, entries) => inner + entries.length),
    );
    return countNested(_latestAttemptGenerations) +
        countNested(_successfulAttemptGenerations) +
        retained +
        blocked;
  }

  Future<OfflineClearPreview> preview({
    required String accountId,
    required OfflineClearCommand command,
  }) {
    final mutationBlocks = _beginMutationBlocks([
      OfflineMutationScope.account(accountId),
    ]);
    return _serialized(() async {
      try {
        await Future.wait(
          mutationBlocks.map((entry) => entry.block.waitForQuiescence()),
        );
        final snapshot = await _capture(accountId);
        return OfflineClearPreview(
          accountId: accountId,
          command: command,
          counts: snapshot.counts,
          sequence: ++_previewSequence,
          contentRevision: snapshot.revisionFor(command),
        );
      } finally {
        _releaseMutationBlocks(mutationBlocks);
      }
    });
  }

  Future<OfflineOwnershipReport> executeClear(OfflineClearPreview preview) {
    final wasCommandBlocked = _commandBlockedAccounts.contains(
      preview.accountId,
    );
    _commandBlockedAccounts.add(preview.accountId);
    final mutationBlocks = _beginMutationBlocks([
      OfflineMutationScope.account(preview.accountId),
    ]);
    return _serialized(() async {
      final failures = <OfflineOwnershipFailure>[];
      await _waitForMutationBlocks(mutationBlocks, failures);
      if (failures.isNotEmpty) {
        return OfflineOwnershipReport(
          reason: null,
          accountId: preview.accountId,
          executedCounts: const OfflineOwnershipCounts(),
          failures: failures,
        );
      }
      final currentSnapshot = await _captureWithFailure(
        preview.accountId,
        failures,
      );
      final executedCounts = currentSnapshot.counts;
      if (failures.isNotEmpty) {
        return OfflineOwnershipReport(
          reason: null,
          accountId: preview.accountId,
          executedCounts: executedCounts,
          failures: failures,
        );
      }
      final currentRevision = currentSnapshot.revisionFor(preview.command);
      if (!_sameCommandCounts(
            preview.command,
            executedCounts,
            preview.counts,
          ) ||
          currentRevision != preview.contentRevision) {
        return OfflineOwnershipReport(
          reason: null,
          accountId: preview.accountId,
          executedCounts: executedCounts,
          changedSincePreview: true,
          currentPreview: OfflineClearPreview(
            accountId: preview.accountId,
            command: preview.command,
            counts: executedCounts,
            sequence: ++_previewSequence,
            contentRevision: currentRevision,
          ),
          failures: const [],
        );
      }
      switch (preview.command) {
        case OfflineClearCommand.cache:
          final failureCount = failures.length;
          await _step(
            OfflineOwnershipStep.store,
            'Unable to clear cached records.',
            () => store.clearAccountCache(preview.accountId),
            failures,
          );
          if (failures.length == failureCount) {
            await _step(
              OfflineOwnershipStep.files,
              'Unable to clear downloaded files.',
              () => files.clearDownloads(preview.accountId),
              failures,
            );
            if (scans case final OfflineLookupOwnershipStore lookups) {
              await _step(
                OfflineOwnershipStep.scanSessions,
                'Unable to clear scanner lookup cache.',
                () => lookups.clearLookupCacheForAccount(preview.accountId),
                failures,
              );
            }
          }
        case OfflineClearCommand.offlineWork:
          final failureCount = failures.length;
          await _step(
            OfflineOwnershipStep.store,
            'Unable to clear drafts and queued work.',
            () => store.clearAccountOfflineWork(preview.accountId),
            failures,
          );
          if (failures.length == failureCount) {
            await _step(
              OfflineOwnershipStep.files,
              'Unable to clear staged transfers.',
              () => files.clearStagedTransfers(preview.accountId),
              failures,
            );
            await _step(
              OfflineOwnershipStep.scanSessions,
              'Unable to clear scan sessions.',
              () => scans.clearForAccount(preview.accountId),
              failures,
            );
          }
      }
      final remaining = await _inspectWithFailure(preview.accountId, failures);
      return OfflineOwnershipReport(
        reason: null,
        accountId: preview.accountId,
        executedCounts: executedCounts,
        remainingCounts: remaining,
        changedSincePreview: false,
        failures: failures,
      );
    }).whenComplete(() {
      _releaseMutationBlocks(mutationBlocks);
      if (!wasCommandBlocked) {
        _commandBlockedAccounts.remove(preview.accountId);
      }
    });
  }

  @override
  Future<OfflineOwnershipReport> apply(OfflineOwnershipIntent intent) {
    final attempt = _startAttempt(intent);
    late final List<_ParticipantBlock> mutationBlocks;
    try {
      mutationBlocks = _beginMutationBlocks(_mutationScopesFor(intent));
    } on Object {
      if (attempt != null) _discardAttempt(attempt);
      rethrow;
    }
    return _serialized(() async {
      final report = await _apply(intent, mutationBlocks);
      _finishMutationBlocks(intent, report, mutationBlocks, attempt);
      return report;
    });
  }

  Future<OfflineOwnershipReport> _apply(
    OfflineOwnershipIntent intent,
    List<_ParticipantBlock> mutationBlocks,
  ) async {
    final failures = <OfflineOwnershipFailure>[];
    if (intent.reason != OfflineOwnershipReason.reauthenticated) {
      await _waitForMutationBlocks(mutationBlocks, failures);
      if (failures.isNotEmpty) {
        return OfflineOwnershipReport(
          reason: intent.reason,
          accountId: intent.accountId,
          executedCounts: const OfflineOwnershipCounts(),
          failures: failures,
        );
      }
    }
    final counts = await _inspectWithFailure(intent.accountId, failures);

    switch (intent.reason) {
      case OfflineOwnershipReason.logout:
        final preserveDrafts =
            intent.draftRetention == DraftRetentionChoice.retainLocally;
        final retainedStagedRequestIds = preserveDrafts
            ? await _draftAttachmentIds(intent.accountId, failures)
            : const <String>{};
        if (retainedStagedRequestIds != null) {
          await _clearAccount(
            intent.accountId,
            preserveDrafts: preserveDrafts,
            retainedStagedRequestIds: retainedStagedRequestIds,
            failures: failures,
          );
        }
      case OfflineOwnershipReason.accountSwitch:
        await _clearAccount(
          intent.accountId,
          preserveDrafts: false,
          retainedStagedRequestIds: const {},
          failures: failures,
        );
      case OfflineOwnershipReason.warehouseSwitch:
        final previousWarehouseId = intent.previousWarehouseId;
        if (previousWarehouseId != null &&
            previousWarehouseId != intent.currentWarehouseId) {
          await _step(
            OfflineOwnershipStep.store,
            'Unable to invalidate the previous warehouse cache.',
            () => store.invalidateWarehouseCache(
              accountId: intent.accountId,
              warehouseId: previousWarehouseId,
            ),
            failures,
          );
          if (scans case final OfflineLookupOwnershipStore lookups) {
            await _step(
              OfflineOwnershipStep.scanSessions,
              'Unable to invalidate scanner lookup cache.',
              () => lookups.clearLookupCacheForWarehouse(
                intent.accountId,
                previousWarehouseId,
              ),
              failures,
            );
          }
          await _step(
            OfflineOwnershipStep.reviewedSyncAuthority,
            'Unable to invalidate reviewed warehouse operations.',
            () => reviews.invalidate(
              accountId: intent.accountId,
              warehouseId: previousWarehouseId,
            ),
            failures,
          );
        }
      case OfflineOwnershipReason.permissionRefresh:
        await _step(
          OfflineOwnershipStep.store,
          'Unable to invalidate permission-scoped cache.',
          () => store.invalidatePermissionScopedCache(intent.accountId),
          failures,
        );
        if (scans case final OfflineLookupOwnershipStore lookups) {
          await _step(
            OfflineOwnershipStep.scanSessions,
            'Unable to invalidate scanner lookup cache.',
            () => lookups.clearLookupCacheForAccount(intent.accountId),
            failures,
          );
        }
        await _step(
          OfflineOwnershipStep.reviewedSyncAuthority,
          'Unable to invalidate reviewed operations.',
          () => reviews.invalidate(accountId: intent.accountId),
          failures,
        );
      case OfflineOwnershipReason.tokenExpiry:
        await _step(
          OfflineOwnershipStep.reviewedSyncAuthority,
          'Unable to invalidate reviewed operations after token expiry.',
          () => reviews.invalidate(accountId: intent.accountId),
          failures,
        );
      case OfflineOwnershipReason.reauthenticated:
        break;
      case OfflineOwnershipReason.revocation:
        final sensitiveFailureCount = failures.length;
        await _step(
          OfflineOwnershipStep.store,
          'Unable to clear offline database data.',
          store.clearAllSensitiveData,
          failures,
        );
        if (failures.length == sensitiveFailureCount) {
          await _step(
            OfflineOwnershipStep.files,
            'Unable to clear all offline files.',
            files.clearAllFiles,
            failures,
          );
          await _step(
            OfflineOwnershipStep.scanSessions,
            'Unable to clear all scan sessions.',
            scans.clearAll,
            failures,
          );
        }
        if (failures.isEmpty) {
          await _step(
            OfflineOwnershipStep.databaseKey,
            'Unable to rotate the offline database key.',
            databaseKeys.rotateAfterRevocation,
            failures,
          );
        } else {
          failures.add(
            const OfflineOwnershipFailure(
              step: OfflineOwnershipStep.databaseKey,
              message:
                  'Database key was not rotated because sensitive data cleanup failed.',
            ),
          );
        }
      case OfflineOwnershipReason.invalidSessionProjection:
        await _step(
          OfflineOwnershipStep.store,
          'Unable to discard the invalid cached session projection.',
          () => store.discardSessionProjection(intent.accountId),
          failures,
        );
    }

    return OfflineOwnershipReport(
      reason: intent.reason,
      accountId: intent.accountId,
      executedCounts: counts,
      failures: failures,
    );
  }

  List<OfflineMutationScope> _mutationScopesFor(OfflineOwnershipIntent intent) {
    return switch (intent.reason) {
      OfflineOwnershipReason.reauthenticated => const [],
      OfflineOwnershipReason.revocation => const [OfflineMutationScope.all()],
      OfflineOwnershipReason.accountSwitch => [
        OfflineMutationScope.account(intent.accountId),
        if (intent.currentAccountId case final current?)
          OfflineMutationScope.account(current),
      ],
      _ => [OfflineMutationScope.account(intent.accountId)],
    };
  }

  List<_ParticipantBlock> _beginMutationBlocks(
    Iterable<OfflineMutationScope> scopes,
  ) {
    final blocks = <_ParticipantBlock>[];
    try {
      for (final scope in scopes) {
        for (final participant in _mutationParticipants) {
          blocks.add(
            _ParticipantBlock(
              scope: scope,
              block: participant.blockMutations(scope),
            ),
          );
        }
      }
      return blocks;
    } on Object {
      _releaseMutationBlocks(blocks);
      rethrow;
    }
  }

  Future<void> _waitForMutationBlocks(
    List<_ParticipantBlock> blocks,
    List<OfflineOwnershipFailure> failures,
  ) async {
    await _step(
      OfflineOwnershipStep.mutationQuiescence,
      'Unable to wait for active offline writes to finish.',
      () => Future.wait(blocks.map((entry) => entry.block.waitForQuiescence())),
      failures,
    );
  }

  void _finishMutationBlocks(
    OfflineOwnershipIntent intent,
    OfflineOwnershipReport report,
    List<_ParticipantBlock> blocks,
    _OwnershipAttempt? attempt,
  ) {
    if (intent.reason == OfflineOwnershipReason.reauthenticated) {
      if (report.completed) {
        final successful = _successfulAttemptGenerations[intent.accountId];
        if (successful != null) {
          for (final entry in successful.entries.toList(growable: false)) {
            final latest =
                _latestAttemptGenerations[intent.accountId]?[entry.key];
            if (latest == entry.value) {
              _unblockGeneration(intent.accountId, entry.key, entry.value);
              _releaseRetainedMutationBlocks(
                intent.accountId,
                entry.key,
                entry.value,
              );
              _removeLatestGeneration(intent.accountId, entry.key, entry.value);
              successful.remove(entry.key);
            }
          }
          if (successful.isEmpty) {
            _successfulAttemptGenerations.remove(intent.accountId);
          }
        }
      }
      return;
    }
    if (attempt == null) {
      _releaseMutationBlocks(blocks);
      return;
    }
    if (report.failures.any(
      (failure) => failure.step == OfflineOwnershipStep.mutationQuiescence,
    )) {
      _discardAttempt(attempt);
      _releaseMutationBlocks(blocks);
      return;
    }
    for (final target in attempt.targets) {
      final isLatest =
          _latestAttemptGenerations[target.accountId]?[target.key] ==
          attempt.generation;
      if (!isLatest || target.isSecondary) {
        _unblockGeneration(target.accountId, target.key, attempt.generation);
        _releaseRetainedMutationBlocks(
          target.accountId,
          target.key,
          attempt.generation,
        );
        if (isLatest) {
          _removeLatestGeneration(
            target.accountId,
            target.key,
            attempt.generation,
          );
        }
        continue;
      }

      final isPersistent = switch (target.reason) {
        OfflineOwnershipReason.warehouseSwitch ||
        OfflineOwnershipReason.permissionRefresh => false,
        _ => true,
      };
      if (!isPersistent && report.completed) {
        _unblockGeneration(target.accountId, target.key, attempt.generation);
        _releaseRetainedMutationBlocks(
          target.accountId,
          target.key,
          attempt.generation,
        );
        _removeLatestGeneration(
          target.accountId,
          target.key,
          attempt.generation,
        );
        continue;
      }

      if (report.completed) {
        _recordSuccessfulAttempt(target, attempt.generation);
      }
      if (target.reason == OfflineOwnershipReason.revocation) {
        late final List<_ParticipantBlock> accountBlocks;
        try {
          accountBlocks = _beginMutationBlocks([
            OfflineMutationScope.account(target.accountId),
          ]);
        } on Object {
          _discardAttempt(attempt);
          _releaseMutationBlocks(blocks);
          rethrow;
        }
        _retainMutationBlocks(
          target.accountId,
          target.key,
          attempt.generation,
          accountBlocks,
        );
        _releaseMutationBlocks(accountBlocks);
      } else {
        _retainMutationBlocks(
          target.accountId,
          target.key,
          attempt.generation,
          blocks,
        );
      }
    }
    _releaseMutationBlocks(blocks);
  }

  _OwnershipAttempt? _startAttempt(OfflineOwnershipIntent intent) {
    if (intent.reason == OfflineOwnershipReason.reauthenticated) return null;
    final generation = ++_attemptGeneration;
    final targets = _attemptTargetsFor(intent);
    for (final target in targets) {
      final key = target.key;
      _blockGeneration(target.accountId, key, generation);
      final latest = _latestAttemptGenerations.putIfAbsent(
        target.accountId,
        () => {},
      );
      final superseded = latest[key];
      latest[key] = generation;
      final successful = _successfulAttemptGenerations[target.accountId];
      successful?.remove(key);
      if (successful?.isEmpty ?? false) {
        _successfulAttemptGenerations.remove(target.accountId);
      }
      if (superseded != null) {
        _unblockGeneration(target.accountId, key, superseded);
        _releaseRetainedMutationBlocks(target.accountId, key, superseded);
      }
    }
    return _OwnershipAttempt(generation: generation, targets: targets);
  }

  void _discardAttempt(_OwnershipAttempt attempt) {
    for (final target in attempt.targets) {
      final key = target.key;
      _unblockGeneration(target.accountId, key, attempt.generation);
      _releaseRetainedMutationBlocks(target.accountId, key, attempt.generation);
      _removeLatestGeneration(target.accountId, key, attempt.generation);
      final successful = _successfulAttemptGenerations[target.accountId];
      if (successful?[key] == attempt.generation) successful?.remove(key);
      if (successful?.isEmpty ?? false) {
        _successfulAttemptGenerations.remove(target.accountId);
      }
    }
  }

  List<_OwnershipAttemptTarget> _attemptTargetsFor(
    OfflineOwnershipIntent intent,
  ) {
    final targets = <_OwnershipAttemptTarget>[
      _OwnershipAttemptTarget(
        accountId: intent.accountId,
        reason: intent.reason,
      ),
    ];
    final current = intent.currentAccountId;
    if (intent.reason == OfflineOwnershipReason.accountSwitch &&
        current != null &&
        current != intent.accountId) {
      targets.add(
        _OwnershipAttemptTarget(
          accountId: current,
          reason: intent.reason,
          isSecondary: true,
        ),
      );
    }
    return targets;
  }

  void _recordSuccessfulAttempt(
    _OwnershipAttemptTarget target,
    int generation,
  ) {
    _successfulAttemptGenerations.putIfAbsent(
      target.accountId,
      () => {},
    )[target.key] = generation;
  }

  void _retainMutationBlocks(
    String accountId,
    _OwnershipBlockKey key,
    int generation,
    List<_ParticipantBlock> candidates,
  ) {
    final matching = candidates
        .where(
          (entry) =>
              !entry.scope.allAccounts &&
              entry.scope.resolvedAccountIds.length == 1 &&
              entry.scope.contains(accountId),
        )
        .toList(growable: false);
    if (matching.isEmpty) return;
    final byReason = _retainedMutationBlocks.putIfAbsent(accountId, () => {});
    final byGeneration = byReason.putIfAbsent(key, () => {});
    if (byGeneration.containsKey(generation)) return;
    byGeneration[generation] = matching;
    for (final entry in matching) {
      entry.retained = true;
    }
  }

  void _releaseRetainedMutationBlocks(
    String accountId,
    _OwnershipBlockKey key,
    int generation,
  ) {
    final byReason = _retainedMutationBlocks[accountId];
    final byGeneration = byReason?[key];
    final retained = byGeneration?.remove(generation);
    if (retained != null) {
      _releaseMutationBlocks(retained, includeRetained: true);
    }
    if (byGeneration?.isEmpty ?? false) byReason?.remove(key);
    if (byReason?.isEmpty ?? false) _retainedMutationBlocks.remove(accountId);
  }

  void _releaseMutationBlocks(
    Iterable<_ParticipantBlock> blocks, {
    bool includeRetained = false,
  }) {
    for (final entry in blocks) {
      if (!entry.retained || includeRetained) entry.block.release();
    }
  }

  bool _isBlocked(String accountId) =>
      _commandBlockedAccounts.contains(accountId) ||
      (_blockedReasons[accountId]?.isNotEmpty ?? false);

  void _blockGeneration(
    String accountId,
    _OwnershipBlockKey key,
    int generation,
  ) {
    _blockedReasons
        .putIfAbsent(accountId, () => {})
        .putIfAbsent(key, () => {})
        .add(generation);
  }

  void _unblockGeneration(
    String accountId,
    _OwnershipBlockKey key,
    int generation,
  ) {
    final reasons = _blockedReasons[accountId];
    if (reasons == null) return;
    final generations = reasons[key];
    generations?.remove(generation);
    if (generations?.isEmpty ?? false) reasons.remove(key);
    if (reasons.isEmpty) _blockedReasons.remove(accountId);
  }

  void _removeLatestGeneration(
    String accountId,
    _OwnershipBlockKey key,
    int generation,
  ) {
    final latest = _latestAttemptGenerations[accountId];
    if (latest?[key] == generation) latest?.remove(key);
    if (latest?.isEmpty ?? false) _latestAttemptGenerations.remove(accountId);
  }

  Future<void> _clearAccount(
    String accountId, {
    required bool preserveDrafts,
    required Set<String> retainedStagedRequestIds,
    required List<OfflineOwnershipFailure> failures,
  }) async {
    final failureCount = failures.length;
    await _step(
      OfflineOwnershipStep.store,
      'Unable to clear account offline data.',
      () => store.clearOwnedAccount(accountId, preserveDrafts: preserveDrafts),
      failures,
    );
    if (failures.length == failureCount) {
      await _step(
        OfflineOwnershipStep.files,
        'Unable to clear account offline files.',
        () => files.clearAccountFiles(
          accountId,
          retainStagedRequestIds: retainedStagedRequestIds,
        ),
        failures,
      );
      await _step(
        OfflineOwnershipStep.scanSessions,
        'Unable to clear account scan sessions.',
        () => scans.clearForAccount(accountId),
        failures,
      );
    }
  }

  Future<Set<String>?> _draftAttachmentIds(
    String accountId,
    List<OfflineOwnershipFailure> failures,
  ) async {
    try {
      return Set.unmodifiable(
        (await store.inspectAccount(accountId)).draftAttachmentRequestIds,
      );
    } on Object catch (error) {
      failures.add(
        OfflineOwnershipFailure(
          step: OfflineOwnershipStep.preview,
          message: 'Unable to inspect retained draft attachments.',
          cause: error,
        ),
      );
      return null;
    }
  }

  Future<OfflineOwnershipCounts> _inspect(String accountId) async {
    return (await _capture(accountId)).counts;
  }

  Future<_OwnershipSnapshot> _capture(String accountId) async {
    final values = await Future.wait<Object>([
      store.inspectAccount(accountId),
      files.inspectAccount(accountId),
      scans.countForAccount(accountId),
      if (scans case final OfflineScanOwnershipInspector inspector)
        inspector.contentIdentitiesForAccount(accountId),
    ]);
    final stored = values[0] as OfflineStoreOwnershipSnapshot;
    final ownedFiles = values[1] as OfflineFileOwnershipSnapshot;
    final lookupStore = scans is OfflineLookupOwnershipStore
        ? scans as OfflineLookupOwnershipStore
        : null;
    final legacyLookupCount = lookupStore == null
        ? 0
        : await lookupStore.countLookupCacheForAccount(accountId);
    final counts = OfflineOwnershipCounts(
      cacheEntries: stored.cacheEntries + legacyLookupCount,
      drafts: stored.drafts,
      outboxOperations: stored.outboxOperations,
      stagedTransfers: ownedFiles.stagedTransfers,
      downloads: ownedFiles.downloads,
      scanSessions: values[2] as int,
    );
    return _OwnershipSnapshot(
      counts: counts,
      storeIdentities: stored.contentIdentities,
      fileIdentities: ownedFiles.contentIdentities,
      scanIdentities: values.length > 3
          ? values[3] as Set<String>
          : {'scan-count:${counts.scanSessions}'},
    );
  }

  Future<_OwnershipSnapshot> _captureWithFailure(
    String accountId,
    List<OfflineOwnershipFailure> failures,
  ) async {
    try {
      return await _capture(accountId);
    } on Object catch (error) {
      failures.add(
        OfflineOwnershipFailure(
          step: OfflineOwnershipStep.preview,
          message: 'Unable to inspect exact offline data counts.',
          cause: error,
        ),
      );
      return const _OwnershipSnapshot(counts: OfflineOwnershipCounts());
    }
  }

  Future<OfflineOwnershipCounts> _inspectWithFailure(
    String accountId,
    List<OfflineOwnershipFailure> failures,
  ) async {
    try {
      return await _inspect(accountId);
    } on Object catch (error) {
      failures.add(
        OfflineOwnershipFailure(
          step: OfflineOwnershipStep.preview,
          message: 'Unable to inspect exact offline data counts.',
          cause: error,
        ),
      );
      return const OfflineOwnershipCounts();
    }
  }

  Future<void> _step(
    OfflineOwnershipStep step,
    String message,
    Future<void> Function() operation,
    List<OfflineOwnershipFailure> failures,
  ) async {
    try {
      await operation();
    } on Object catch (error) {
      failures.add(
        OfflineOwnershipFailure(step: step, message: message, cause: error),
      );
    }
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}

final class _ParticipantBlock {
  _ParticipantBlock({required this.scope, required this.block});

  final OfflineMutationScope scope;
  final OfflineMutationBlock block;
  bool retained = false;
}

final class _OwnershipAttempt {
  const _OwnershipAttempt({required this.generation, required this.targets});

  final int generation;
  final List<_OwnershipAttemptTarget> targets;
}

final class _OwnershipAttemptTarget {
  const _OwnershipAttemptTarget({
    required this.accountId,
    required this.reason,
    this.isSecondary = false,
  });

  final String accountId;
  final OfflineOwnershipReason reason;
  final bool isSecondary;

  _OwnershipBlockKey get key => _OwnershipBlockKey(
    reason,
    isSecondary
        ? _OwnershipSlot.secondaryTransient
        : _OwnershipSlot.primaryPersistent,
  );
}

enum _OwnershipSlot { primaryPersistent, secondaryTransient }

final class _OwnershipBlockKey {
  const _OwnershipBlockKey(this.reason, this.slot);

  final OfflineOwnershipReason reason;
  final _OwnershipSlot slot;

  @override
  bool operator ==(Object other) =>
      other is _OwnershipBlockKey &&
      reason == other.reason &&
      slot == other.slot;

  @override
  int get hashCode => Object.hash(reason, slot);
}

final class _OwnershipSnapshot {
  const _OwnershipSnapshot({
    required this.counts,
    this.storeIdentities = const {},
    this.fileIdentities = const {},
    this.scanIdentities = const {},
  });

  final OfflineOwnershipCounts counts;
  final Set<String> storeIdentities;
  final Set<String> fileIdentities;
  final Set<String> scanIdentities;

  String revisionFor(OfflineClearCommand command) {
    final prefixes = switch (command) {
      OfflineClearCommand.cache => const ['cache:', 'download:', 'lookup:'],
      OfflineClearCommand.offlineWork => const [
        'draft:',
        'outbox:',
        'staged:',
        'scan-session:',
      ],
    };
    final identities = <String>{
      ...storeIdentities,
      ...fileIdentities,
      ...scanIdentities,
    }.where((identity) => prefixes.any(identity.startsWith)).toList()..sort();
    return _stableRevision(identities);
  }
}

String _stableRevision(Iterable<String> values) {
  var hash = 0xcbf29ce484222325;
  for (final codeUnit in values.join('\n').codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

bool _sameCommandCounts(
  OfflineClearCommand command,
  OfflineOwnershipCounts left,
  OfflineOwnershipCounts right,
) => switch (command) {
  OfflineClearCommand.cache =>
    left.cacheEntries == right.cacheEntries &&
        left.downloads == right.downloads,
  OfflineClearCommand.offlineWork =>
    left.drafts == right.drafts &&
        left.outboxOperations == right.outboxOperations &&
        left.stagedTransfers == right.stagedTransfers &&
        left.scanSessions == right.scanSessions,
};
