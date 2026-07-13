import 'immutable_snapshot.dart';

final class OutboxOperationOutput {
  OutboxOperationOutput({
    required this.version,
    required Map<String, Object?> data,
  }) : assert(version > 0),
       data = immutableMapSnapshot(data);

  final int version;
  final Map<String, Object?> data;
}
