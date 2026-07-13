import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/auth/domain/entities/app_user.dart';
import 'package:rims_frontend/features/offline/data/datasources/operation_status_remote_datasource.dart';
import 'package:rims_frontend/features/offline/data/repositories/memory_outbox_repository.dart';
import 'package:rims_frontend/features/offline/domain/entities/network_reachability.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation.dart';
import 'package:rims_frontend/features/offline/domain/services/network_status_service.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_executor.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_permission_policy.dart';
import 'package:rims_frontend/features/offline/domain/services/outbox_state_machine.dart';

void main() {
  test(
    'permission policy derives ordinary allowed kinds and stable fingerprint',
    () {
      const policy = OutboxPermissionPolicy();
      const first = AppUser(
        id: 7,
        username: 'operator',
        realName: 'Operator',
        roleCode: 'operator',
        roleName: 'Operator',
        permissionCodes: {
          'stocktake:confirm',
          'file:upload',
          'document:create',
        },
      );
      const reordered = AppUser(
        id: 7,
        username: 'operator',
        realName: 'Operator',
        roleCode: 'operator',
        roleName: 'Operator',
        permissionCodes: {
          'document:create',
          'file:upload',
          'stocktake:confirm',
        },
      );
      const revoked = AppUser(
        id: 7,
        username: 'operator',
        realName: 'Operator',
        roleCode: 'operator',
        roleName: 'Operator',
        permissionCodes: {'file:upload', 'stocktake:confirm'},
      );

      final context = policy.contextFor(user: first, warehouseId: 11);
      final reorderedContext = policy.contextFor(
        user: reordered,
        warehouseId: 11,
      );
      final revokedContext = policy.contextFor(user: revoked, warehouseId: 11);

      expect(context.allowedKinds, {
        OutboxOperationKind.attachmentUpload,
        OutboxOperationKind.documentCreate,
        OutboxOperationKind.stocktakeConfirm,
      });
      expect(context.permissionStamp, reorderedContext.permissionStamp);
      expect(revokedContext.permissionStamp, isNot(context.permissionStamp));
      expect(
        revokedContext.allowedKinds,
        isNot(contains(OutboxOperationKind.documentCreate)),
      );
    },
  );

  test(
    'admin allowed kinds come only from actual backend permission codes',
    () {
      const policy = OutboxPermissionPolicy();
      const admin = AppUser(
        id: 1,
        username: 'admin',
        realName: 'Admin',
        roleCode: 'admin',
        roleName: 'Administrator',
        permissionCodes: {
          'document:create',
          'document:complete',
          'stocktake:confirm',
          'stocktake:settle',
          'file:upload',
        },
      );

      final context = policy.contextFor(user: admin, warehouseId: 11);

      expect(context.allowedKinds, OutboxOperationKind.values.toSet());
    },
  );

  late DateTime now;
  late MemoryOutboxRepository repository;
  late _NetworkStatusService network;
  late _StatusDataSource status;
  late _Handler handler;
  late OutboxExecutionContext? context;
  late List<Duration> delays;
  late OutboxExecutor executor;

  OutboxReview review(Set<String> ids) => OutboxReview(
    operationIds: ids,
    accountId: '7',
    warehouseId: 11,
    permissionStamp: context?.permissionStamp ?? 'stock:write@1',
  );

  Future<OutboxOperation> stored(String id) async => (await repository.list(
    '7',
  )).dataOrNull!.singleWhere((item) => item.operationId == id);

  Future<OutboxState> state(String id) async => (await stored(id)).state;

  Future<void> enqueueUnknown(String id) async {
    await repository.enqueue(_operation(id));
    await repository.transition(
      accountId: '7',
      operationId: id,
      next: OutboxState.syncing,
    );
    await repository.transition(
      accountId: '7',
      operationId: id,
      next: OutboxState.retryableFailure,
      failure: const NetworkFailure(message: 'result unknown'),
    );
    now = now.add(const Duration(seconds: 3));
  }

  setUp(() {
    now = DateTime.utc(2026, 7, 13, 8);
    repository = MemoryOutboxRepository(
      stateMachine: OutboxStateMachine(
        now: () => now,
        retryBackoff: (attempt) => Duration(seconds: attempt * 3),
      ),
      now: () => now,
    );
    network = _NetworkStatusService();
    status = _StatusDataSource();
    handler = _Handler();
    context = const OutboxExecutionContext(
      accountId: '7',
      warehouseId: 11,
      permissionStamp: 'stock:write@1',
      allowedKinds: {OutboxOperationKind.documentCreate},
    );
    delays = [];
    executor = OutboxExecutor(
      repository: repository,
      networkStatusService: network,
      statusDataSource: status,
      handlers: [handler],
      contextReader: () => context,
      delay: (duration) async => delays.add(duration),
      probeBackoff: (attempt) => Duration(seconds: attempt),
      maxStatusProbes: 3,
    );
  });

  test(
    'requires matching current account warehouse permission and review',
    () async {
      await repository.enqueue(_operation('op'));

      for (final review in [
        const OutboxReview(
          operationIds: {'op'},
          accountId: '8',
          warehouseId: 11,
          permissionStamp: 'stock:write@1',
        ),
        const OutboxReview(
          operationIds: {'op'},
          accountId: '7',
          warehouseId: 12,
          permissionStamp: 'stock:write@1',
        ),
        const OutboxReview(
          operationIds: {'op'},
          accountId: '7',
          warehouseId: 11,
          permissionStamp: 'stock:write@0',
        ),
      ]) {
        final report = await executor.execute(review);
        expect(report.failure, isA<AuthorizationFailure>());
      }

      context = const OutboxExecutionContext(
        accountId: '7',
        warehouseId: 11,
        permissionStamp: 'stock:write@2',
        allowedKinds: {},
      );
      final denied = await executor.execute(
        const OutboxReview(
          operationIds: {'op'},
          accountId: '7',
          warehouseId: 11,
          permissionStamp: 'stock:write@2',
        ),
      );

      expect(denied.failure, isA<AuthorizationFailure>());
      expect(handler.calls, isEmpty);
      expect(network.verifyCalls, 0);
    },
  );

  test('unreviewed operation never executes', () async {
    await repository.enqueue(_operation('reviewed'));
    await repository.enqueue(_operation('not-reviewed'));

    final report = await executor.execute(review({'reviewed'}));

    expect(report.succeededOperationIds, ['reviewed']);
    expect(handler.calls, ['reviewed']);
    expect(state('not-reviewed'), completion(OutboxState.queued));
  });

  test(
    'completed unknown result probes then replays original once for body',
    () async {
      await enqueueUnknown('op');
      status.results.add(
        Success(
          OperationStatus(
            state: OperationState.completed,
            statusCode: 201,
            expiresAt: now.add(const Duration(days: 1)),
          ),
        ),
      );
      handler.results.add(const Success({'documentId': 42}));

      final report = await executor.execute(review({'op'}));

      expect(report.succeededOperationIds, ['op']);
      expect(status.keys, ['key-op']);
      expect(handler.calls, ['op']);
      expect(handler.seenKeys, ['key-op']);
      expect(await state('op'), OutboxState.succeeded);
    },
  );

  test('processing unknown result waits with bounded probes', () async {
    await enqueueUnknown('op');
    status.results.addAll(
      List.generate(
        3,
        (_) => Success(
          OperationStatus(
            state: OperationState.processing,
            statusCode: 0,
            expiresAt: now.add(const Duration(days: 1)),
          ),
        ),
      ),
    );

    final report = await executor.execute(review({'op'}));

    expect(report.failure, isA<NetworkFailure>());
    expect(status.keys, ['key-op', 'key-op', 'key-op']);
    expect(delays, const [Duration(seconds: 1), Duration(seconds: 2)]);
    expect(handler.calls, isEmpty);
    expect(await state('op'), OutboxState.retryableFailure);
    expect(
      (await stored('op')).nextAttemptAt,
      now.add(const Duration(seconds: 6)),
    );
  });

  test('a later foreground retry keeps probing a processing result', () async {
    await enqueueUnknown('op');
    status.results.addAll(
      List.generate(
        3,
        (_) => Success(
          OperationStatus(
            state: OperationState.processing,
            statusCode: 0,
            expiresAt: now.add(const Duration(days: 1)),
          ),
        ),
      ),
    );
    await executor.execute(review({'op'}));
    now = now.add(const Duration(seconds: 6));
    status.results.add(
      Success(
        OperationStatus(
          state: OperationState.completed,
          statusCode: 201,
          expiresAt: now.add(const Duration(days: 1)),
        ),
      ),
    );

    await executor.execute(review({'op'}));

    expect(status.keys, ['key-op', 'key-op', 'key-op', 'key-op']);
    expect(handler.calls, ['op']);
    expect(await state('op'), OutboxState.succeeded);
  });

  test(
    'absent unknown result retries original request with same key',
    () async {
      await enqueueUnknown('op');
      status.results.add(const FailureResult(NotFoundFailure()));

      await executor.execute(review({'op'}));

      expect(status.keys, ['key-op']);
      expect(handler.seenKeys, ['key-op']);
      expect(await state('op'), OutboxState.succeeded);
    },
  );

  test(
    '401 pauses batch and returns operation to explicit retryable state',
    () async {
      await repository.enqueue(_operation('a'));
      await repository.enqueue(_operation('b'));
      handler.results.add(
        const FailureResult(AuthenticationFailure(statusCode: 401)),
      );

      final report = await executor.execute(review({'a', 'b'}));

      expect(report.paused, isTrue);
      expect(report.failure, isA<AuthenticationFailure>());
      expect(handler.calls, ['a']);
      expect(await state('a'), OutboxState.retryableFailure);
      expect(await state('b'), OutboxState.queued);
    },
  );

  test(
    '403 is permanent and 409 is conflict without payload or key rewrite',
    () async {
      final forbidden = _operation('forbidden', payload: const {'quantity': 1});
      final conflict = _operation('conflict', payload: const {'quantity': 2});
      await repository.enqueue(forbidden);
      await repository.enqueue(conflict);
      handler.onCall = (operation) async => operation.operationId == 'forbidden'
          ? const FailureResult(AuthorizationFailure(statusCode: 403))
          : const FailureResult(ConflictFailure(statusCode: 409));

      await executor.execute(review({'forbidden', 'conflict'}));

      final storedForbidden = await stored('forbidden');
      final storedConflict = await stored('conflict');
      expect(storedForbidden.state, OutboxState.permanentFailure);
      expect(storedConflict.state, OutboxState.conflict);
      expect(storedForbidden.payload, forbidden.payload);
      expect(storedConflict.payload, conflict.payload);
      expect(storedForbidden.idempotencyKey, forbidden.idempotencyKey);
      expect(storedConflict.idempotencyKey, conflict.idempotencyKey);
    },
  );

  test(
    'verified connectivity and active session are required before network',
    () async {
      await repository.enqueue(_operation('op'));
      network.next = NetworkReachability.unreachable;

      final offline = await executor.execute(review({'op'}));
      expect(offline.failure, isA<NetworkFailure>());
      expect(handler.calls, isEmpty);
      expect(await state('op'), OutboxState.queued);

      network.next = NetworkReachability.online;
      context = null;
      final signedOut = await executor.execute(review({'op'}));
      expect(signedOut.failure, isA<AuthenticationFailure>());
      expect(handler.calls, isEmpty);
    },
  );

  test(
    'persists syncing before handler network activity and runs one at a time',
    () async {
      await repository.enqueue(_operation('a'));
      await repository.enqueue(_operation('b'));
      handler.onCall = (operation) async {
        expect(await state(operation.operationId), OutboxState.syncing);
        return const Success(null);
      };

      await executor.execute(review({'a', 'b'}));

      expect(handler.maxConcurrentCalls, 1);
      expect(handler.calls, ['a', 'b']);
    },
  );

  test('duplicate foreground trigger never duplicates delivery', () async {
    await repository.enqueue(_operation('op'));
    final gate = Completer<Result<Object?>>();
    handler.onCall = (_) => gate.future;

    final first = executor.execute(review({'op'}));
    await handler.called.future;
    final duplicate = await executor.execute(review({'op'}));
    gate.complete(const Success(null));
    await first;

    expect(duplicate.failure, isA<StateFailure>());
    expect(handler.calls, ['op']);
  });

  test('connectivity changes do not auto-start executor', () async {
    await repository.enqueue(_operation('op'));

    network.emit(NetworkReachability.online);
    await Future<void>.delayed(Duration.zero);

    expect(network.verifyCalls, 0);
    expect(handler.calls, isEmpty);
    expect(await state('op'), OutboxState.queued);
  });

  test(
    'revalidates context before every operation and invalidates review',
    () async {
      await repository.enqueue(_operation('a'));
      await repository.enqueue(_operation('b'));
      handler.onCall = (operation) async {
        if (operation.operationId == 'a') {
          context = const OutboxExecutionContext(
            accountId: '7',
            warehouseId: 11,
            permissionStamp: 'stock:write@2',
            allowedKinds: {OutboxOperationKind.documentCreate},
          );
        }
        return const Success(null);
      };

      final report = await executor.execute(review({'a', 'b'}));

      expect(handler.calls, ['a']);
      expect(network.verifyCalls, 1);
      expect(report.paused, isTrue);
      expect(report.reviewInvalidated, isTrue);
      expect(report.skippedOperationReasons['b'], 'review_invalidated');
      expect(await state('b'), OutboxState.queued);
    },
  );

  test(
    'revalidates connectivity before every operation and pauses batch',
    () async {
      await repository.enqueue(_operation('a'));
      await repository.enqueue(_operation('b'));
      handler.onCall = (operation) async {
        if (operation.operationId == 'a') {
          network.next = NetworkReachability.offline;
        }
        return const Success(null);
      };

      final report = await executor.execute(review({'a', 'b'}));

      expect(handler.calls, ['a']);
      expect(network.verifyCalls, 2);
      expect(report.paused, isTrue);
      expect(report.reviewInvalidated, isFalse);
      expect(report.skippedOperationReasons['b'], 'connectivity_unverified');
      expect(await state('b'), OutboxState.queued);
    },
  );

  test('dynamically drains a reviewed dependency chain exactly once', () async {
    await repository.enqueue(
      _operation(
        'attachment',
        kind: OutboxOperationKind.attachmentUpload,
        reviewStamp: '7\u000011\u0000chain@1',
      ),
    );
    await repository.enqueue(
      _operation('create', reviewStamp: '7\u000011\u0000chain@1'),
      dependencies: const {'attachment'},
    );
    await repository.enqueue(
      _operation(
        'complete',
        kind: OutboxOperationKind.documentComplete,
        reviewStamp: '7\u000011\u0000chain@1',
      ),
      dependencies: const {'create'},
    );
    final attachmentHandler = _Handler(
      kind: OutboxOperationKind.attachmentUpload,
    );
    final createHandler = _Handler();
    final completeHandler = _Handler(
      kind: OutboxOperationKind.documentComplete,
    );
    context = const OutboxExecutionContext(
      accountId: '7',
      warehouseId: 11,
      permissionStamp: 'chain@1',
      allowedKinds: {
        OutboxOperationKind.attachmentUpload,
        OutboxOperationKind.documentCreate,
        OutboxOperationKind.documentComplete,
      },
    );
    final chainExecutor = OutboxExecutor(
      repository: repository,
      networkStatusService: network,
      statusDataSource: status,
      handlers: [attachmentHandler, createHandler, completeHandler],
      contextReader: () => context,
      delay: (_) async {},
    );

    final report = await chainExecutor.execute(
      const OutboxReview(
        operationIds: {'attachment', 'create', 'complete', 'missing'},
        accountId: '7',
        warehouseId: 11,
        permissionStamp: 'chain@1',
      ),
    );

    expect(report.succeededOperationIds, ['attachment', 'create', 'complete']);
    expect(attachmentHandler.calls, ['attachment']);
    expect(createHandler.calls, ['create']);
    expect(completeHandler.calls, ['complete']);
    expect(network.verifyCalls, 3);
    expect(report.skippedOperationReasons['missing'], 'not_ready');
  });
}

OutboxOperation _operation(
  String id, {
  Map<String, Object?> payload = const {},
  OutboxOperationKind kind = OutboxOperationKind.documentCreate,
  String reviewStamp = '7\u000011\u0000stock:write@1',
}) {
  final now = DateTime.utc(2026, 7, 13, 8);
  return OutboxOperation(
    operationId: id,
    idempotencyKey: 'key-$id',
    accountId: '7',
    warehouseId: 11,
    kind: kind,
    payload: payload,
    state: OutboxState.queued,
    createdAt: now,
    confirmedAt: now,
    reviewStamp: reviewStamp,
  );
}

final class _Handler implements OutboxOperationHandler {
  _Handler({this.kind = OutboxOperationKind.documentCreate});

  @override
  final OutboxOperationKind kind;

  @override
  String get statusScope => 'POST /api/v1/documents';

  final List<Result<Object?>> results = [];
  final List<String> calls = [];
  final List<String> seenKeys = [];
  Future<Result<Object?>> Function(OutboxOperation operation)? onCall;
  final Completer<void> called = Completer<void>();
  int concurrentCalls = 0;
  int maxConcurrentCalls = 0;

  @override
  Future<Result<Object?>> execute(OutboxOperation operation) async {
    calls.add(operation.operationId);
    seenKeys.add(operation.idempotencyKey);
    concurrentCalls += 1;
    maxConcurrentCalls = concurrentCalls > maxConcurrentCalls
        ? concurrentCalls
        : maxConcurrentCalls;
    if (!called.isCompleted) called.complete();
    try {
      final callback = onCall;
      if (callback != null) return await callback(operation);
      return results.isEmpty ? const Success(null) : results.removeAt(0);
    } finally {
      concurrentCalls -= 1;
    }
  }
}

final class _StatusDataSource implements OperationStatusRemoteDataSource {
  final List<Result<OperationStatus>> results = [];
  final List<String> keys = [];

  @override
  Future<Result<OperationStatus>> loadStatus({
    required String key,
    required String scope,
  }) async {
    keys.add(key);
    return results.removeAt(0);
  }
}

final class _NetworkStatusService implements NetworkStatusService {
  final StreamController<NetworkReachability> _changes =
      StreamController.broadcast();
  NetworkReachability next = NetworkReachability.online;
  int verifyCalls = 0;

  @override
  NetworkReachability get current => next;

  @override
  Stream<NetworkReachability> get changes => _changes.stream;

  void emit(NetworkReachability value) => _changes.add(value);

  @override
  Future<NetworkReachability> verify() async {
    verifyCalls += 1;
    return next;
  }

  @override
  void markOnlineFromRequest() {}

  @override
  Future<void> dispose() => _changes.close();
}

extension<T> on Result<T> {
  T? get dataOrNull => when(success: (data) => data, failure: (_) => null);
}
