import '../entities/outbox_operation.dart';
import 'outbox_executor.dart';

final class OutboxStatusBuckets {
  const OutboxStatusBuckets({
    required this.waiting,
    required this.attention,
    required this.completed,
  });

  final List<OutboxOperation> waiting;
  final List<OutboxOperation> attention;
  final List<OutboxOperation> completed;
}

final class OutboxStatusClassifier {
  const OutboxStatusClassifier();

  List<OutboxOperation> visibleOperations({
    required Iterable<OutboxOperation> operations,
    required OutboxExecutionContext context,
  }) {
    return operations
        .where(
          (operation) =>
              operation.accountId == context.accountId &&
              operation.warehouseId == context.warehouseId,
        )
        .toList(growable: false);
  }

  Set<String> deniedOperationIds({
    required Iterable<OutboxOperation> operations,
    required OutboxExecutionContext context,
  }) {
    return operations
        .where((operation) => !context.allowedKinds.contains(operation.kind))
        .map((operation) => operation.operationId)
        .toSet();
  }

  OutboxStatusBuckets classify({
    required Iterable<OutboxOperation> operations,
    Set<String> permissionBlockedOperationIds = const {},
  }) {
    final visible = operations.toList(growable: false);
    return OutboxStatusBuckets(
      waiting: visible
          .where(
            (operation) =>
                !permissionBlockedOperationIds.contains(
                  operation.operationId,
                ) &&
                (operation.state == OutboxState.queued ||
                    operation.state == OutboxState.retryableFailure ||
                    operation.state == OutboxState.syncing),
          )
          .toList(growable: false),
      attention: visible
          .where(
            (operation) =>
                permissionBlockedOperationIds.contains(operation.operationId) ||
                operation.state == OutboxState.conflict ||
                operation.state == OutboxState.permanentFailure,
          )
          .toList(growable: false),
      completed: visible
          .where(
            (operation) =>
                !permissionBlockedOperationIds.contains(
                  operation.operationId,
                ) &&
                (operation.state == OutboxState.succeeded ||
                    operation.state == OutboxState.cancelled),
          )
          .toList(growable: false),
    );
  }
}
