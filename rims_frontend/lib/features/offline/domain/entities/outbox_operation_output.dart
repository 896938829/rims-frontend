final class OutboxOperationOutput {
  const OutboxOperationOutput({required this.version, required this.data})
    : assert(version > 0);

  final int version;
  final Map<String, Object?> data;
}
