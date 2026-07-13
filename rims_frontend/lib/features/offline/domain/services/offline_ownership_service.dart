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
  });

  final int cacheEntries;
  final int drafts;
  final int outboxOperations;
  final Set<String> draftAttachmentRequestIds;
}

final class OfflineFileOwnershipSnapshot {
  const OfflineFileOwnershipSnapshot({
    this.stagedTransfers = 0,
    this.downloads = 0,
  });

  final int stagedTransfers;
  final int downloads;
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
  });

  final String accountId;
  final OfflineClearCommand command;
  final OfflineOwnershipCounts counts;
  final int sequence;
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
    this.remainingCounts = const OfflineOwnershipCounts(),
  }) : failures = List.unmodifiable(failures);

  final OfflineOwnershipReason? reason;
  final String accountId;
  final OfflineOwnershipCounts executedCounts;
  final OfflineOwnershipCounts remainingCounts;
  final List<OfflineOwnershipFailure> failures;
  final bool changedSincePreview;

  bool get completed => failures.isEmpty;
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

abstract interface class OfflineReviewInvalidator {
  Future<void> invalidate({required String accountId, int? warehouseId});
}

abstract interface class OfflineDatabaseKeyManager {
  Future<void> rotateAfterRevocation();
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
  });

  final OfflineOwnershipStore store;
  final OfflineOwnedFileStore files;
  final OfflineOwnedScanStore scans;
  final OfflineReviewInvalidator reviews;
  final OfflineDatabaseKeyManager databaseKeys;

  final Map<String, Set<OfflineOwnershipReason>> _blockedReasons = {};
  final Set<String> _commandBlockedAccounts = {};
  final Set<String> _successfulRevocations = {};
  Future<void> _tail = Future<void>.value();
  int _previewSequence = 0;

  @override
  bool canSync(String accountId) => !_isBlocked(accountId);

  @override
  bool canAccessOfflineData(String accountId) => !_isBlocked(accountId);

  Future<OfflineClearPreview> preview({
    required String accountId,
    required OfflineClearCommand command,
  }) {
    return _serialized(() async {
      final counts = await _inspect(accountId);
      return OfflineClearPreview(
        accountId: accountId,
        command: command,
        counts: counts,
        sequence: ++_previewSequence,
      );
    });
  }

  Future<OfflineOwnershipReport> executeClear(OfflineClearPreview preview) {
    final wasCommandBlocked = _commandBlockedAccounts.contains(
      preview.accountId,
    );
    _commandBlockedAccounts.add(preview.accountId);
    return _serialized(() async {
      final failures = <OfflineOwnershipFailure>[];
      final executedCounts = await _inspectWithFailure(
        preview.accountId,
        failures,
      );
      switch (preview.command) {
        case OfflineClearCommand.cache:
          await _step(
            OfflineOwnershipStep.store,
            'Unable to clear cached records.',
            () => store.clearAccountCache(preview.accountId),
            failures,
          );
          await _step(
            OfflineOwnershipStep.files,
            'Unable to clear downloaded files.',
            () => files.clearDownloads(preview.accountId),
            failures,
          );
        case OfflineClearCommand.offlineWork:
          await _step(
            OfflineOwnershipStep.store,
            'Unable to clear drafts and queued work.',
            () => store.clearAccountOfflineWork(preview.accountId),
            failures,
          );
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
      final remaining = await _inspectWithFailure(preview.accountId, failures);
      return OfflineOwnershipReport(
        reason: null,
        accountId: preview.accountId,
        executedCounts: executedCounts,
        remainingCounts: remaining,
        changedSincePreview: executedCounts != preview.counts,
        failures: failures,
      );
    }).whenComplete(() {
      if (!wasCommandBlocked) {
        _commandBlockedAccounts.remove(preview.accountId);
      }
    });
  }

  @override
  Future<OfflineOwnershipReport> apply(OfflineOwnershipIntent intent) {
    _blockBefore(intent);
    return _serialized(() => _apply(intent));
  }

  Future<OfflineOwnershipReport> _apply(OfflineOwnershipIntent intent) async {
    final failures = <OfflineOwnershipFailure>[];
    final counts = await _inspectWithFailure(intent.accountId, failures);

    switch (intent.reason) {
      case OfflineOwnershipReason.logout:
        final preserveDrafts =
            intent.draftRetention == DraftRetentionChoice.retainLocally;
        await _clearAccount(
          intent.accountId,
          preserveDrafts: preserveDrafts,
          retainedStagedRequestIds: preserveDrafts
              ? await _draftAttachmentIds(intent.accountId, failures)
              : const {},
          failures: failures,
        );
      case OfflineOwnershipReason.accountSwitch:
        await _clearAccount(
          intent.accountId,
          preserveDrafts: false,
          retainedStagedRequestIds: const {},
          failures: failures,
        );
        final current = intent.currentAccountId;
        if (current != null && failures.isEmpty) {
          _unblock(current, OfflineOwnershipReason.accountSwitch);
        }
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
        if (failures.isEmpty) {
          _unblock(intent.accountId, OfflineOwnershipReason.warehouseSwitch);
        }
      case OfflineOwnershipReason.permissionRefresh:
        await _step(
          OfflineOwnershipStep.store,
          'Unable to invalidate permission-scoped cache.',
          () => store.invalidatePermissionScopedCache(intent.accountId),
          failures,
        );
        await _step(
          OfflineOwnershipStep.reviewedSyncAuthority,
          'Unable to invalidate reviewed operations.',
          () => reviews.invalidate(accountId: intent.accountId),
          failures,
        );
        if (failures.isEmpty) {
          _unblock(intent.accountId, OfflineOwnershipReason.permissionRefresh);
        }
      case OfflineOwnershipReason.tokenExpiry:
        await _step(
          OfflineOwnershipStep.reviewedSyncAuthority,
          'Unable to invalidate reviewed operations after token expiry.',
          () => reviews.invalidate(accountId: intent.accountId),
          failures,
        );
      case OfflineOwnershipReason.reauthenticated:
        if (failures.isEmpty) {
          _unblock(intent.accountId, OfflineOwnershipReason.logout);
          _unblock(intent.accountId, OfflineOwnershipReason.tokenExpiry);
          _unblock(
            intent.accountId,
            OfflineOwnershipReason.invalidSessionProjection,
          );
          if (_successfulRevocations.remove(intent.accountId)) {
            _unblock(intent.accountId, OfflineOwnershipReason.revocation);
          }
        }
      case OfflineOwnershipReason.revocation:
        await _step(
          OfflineOwnershipStep.store,
          'Unable to clear offline database data.',
          store.clearAllSensitiveData,
          failures,
        );
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
        if (failures.isEmpty) _successfulRevocations.add(intent.accountId);
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

  void _blockBefore(OfflineOwnershipIntent intent) {
    switch (intent.reason) {
      case OfflineOwnershipReason.logout ||
          OfflineOwnershipReason.tokenExpiry ||
          OfflineOwnershipReason.revocation ||
          OfflineOwnershipReason.invalidSessionProjection:
        _block(intent.accountId, intent.reason);
      case OfflineOwnershipReason.accountSwitch:
        _block(intent.accountId, intent.reason);
        final current = intent.currentAccountId;
        if (current != null) _block(current, intent.reason);
      case OfflineOwnershipReason.warehouseSwitch ||
          OfflineOwnershipReason.permissionRefresh:
        _block(intent.accountId, intent.reason);
      case OfflineOwnershipReason.reauthenticated:
        break;
    }
  }

  bool _isBlocked(String accountId) =>
      _commandBlockedAccounts.contains(accountId) ||
      (_blockedReasons[accountId]?.isNotEmpty ?? false);

  void _block(String accountId, OfflineOwnershipReason reason) {
    _blockedReasons.putIfAbsent(accountId, () => {}).add(reason);
  }

  void _unblock(String accountId, OfflineOwnershipReason reason) {
    final reasons = _blockedReasons[accountId];
    if (reasons == null) return;
    reasons.remove(reason);
    if (reasons.isEmpty) _blockedReasons.remove(accountId);
  }

  Future<void> _clearAccount(
    String accountId, {
    required bool preserveDrafts,
    required Set<String> retainedStagedRequestIds,
    required List<OfflineOwnershipFailure> failures,
  }) async {
    await _step(
      OfflineOwnershipStep.store,
      'Unable to clear account offline data.',
      () => store.clearOwnedAccount(accountId, preserveDrafts: preserveDrafts),
      failures,
    );
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

  Future<Set<String>> _draftAttachmentIds(
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
      return const {};
    }
  }

  Future<OfflineOwnershipCounts> _inspect(String accountId) async {
    final values = await Future.wait<Object>([
      store.inspectAccount(accountId),
      files.inspectAccount(accountId),
      scans.countForAccount(accountId),
    ]);
    final stored = values[0] as OfflineStoreOwnershipSnapshot;
    final ownedFiles = values[1] as OfflineFileOwnershipSnapshot;
    return OfflineOwnershipCounts(
      cacheEntries: stored.cacheEntries,
      drafts: stored.drafts,
      outboxOperations: stored.outboxOperations,
      stagedTransfers: ownedFiles.stagedTransfers,
      downloads: ownedFiles.downloads,
      scanSessions: values[2] as int,
    );
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
