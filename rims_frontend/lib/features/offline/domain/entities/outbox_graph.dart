import 'outbox_operation.dart';
export 'outbox_operation_output.dart';

final class OutboxGraph {
  OutboxGraph({
    required List<OutboxOperation> operations,
    Map<String, Set<String>> dependencies = const {},
  }) : operations = List.unmodifiable(operations),
       dependencies = Map.unmodifiable({
         for (final entry in dependencies.entries)
           entry.key: Set.unmodifiable(entry.value),
       });

  final List<OutboxOperation> operations;
  final Map<String, Set<String>> dependencies;
}
