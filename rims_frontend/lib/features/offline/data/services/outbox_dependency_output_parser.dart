import '../../domain/entities/outbox_operation_output.dart';

enum OutboxDependencyOutputShape { document, attachment, lifecycle }

int requireAuthoritativeDocumentId(
  Map<String, OutboxOperationOutput> dependencyOutputs, {
  required Set<OutboxDependencyOutputShape> allowedShapes,
  Set<String>? allowedLifecycleOperationKinds,
}) {
  if (dependencyOutputs.length != 1) {
    throw const FormatException(
      'Exactly one direct dependency output is required.',
    );
  }
  final output = dependencyOutputs.values.single;
  if (output.version != 1) {
    throw const FormatException('Unsupported dependency output version.');
  }
  final data = output.data;
  final shape = _sameKeys(data, const {'documentId'})
      ? OutboxDependencyOutputShape.document
      : _sameKeys(data, const {'attachmentId', 'documentId'})
      ? OutboxDependencyOutputShape.attachment
      : _sameKeys(data, const {'documentId', 'operationKind'})
      ? OutboxDependencyOutputShape.lifecycle
      : throw const FormatException('Invalid dependency output shape.');
  if (!allowedShapes.contains(shape)) {
    throw const FormatException('Unexpected dependency output shape.');
  }

  final documentId = data['documentId'];
  if (documentId is! int || documentId <= 0) {
    throw const FormatException('Invalid authoritative document ID.');
  }
  if (shape == OutboxDependencyOutputShape.attachment) {
    final attachmentId = data['attachmentId'];
    if (attachmentId is! int || attachmentId <= 0) {
      throw const FormatException('Invalid authoritative attachment ID.');
    }
  }
  if (shape == OutboxDependencyOutputShape.lifecycle) {
    final operationKind = data['operationKind'];
    if (operationKind != 'document_complete' &&
        operationKind != 'stocktake_confirm' &&
        operationKind != 'stocktake_settle' &&
        operationKind != 'document_complete_reference' &&
        operationKind != 'stocktake_confirm_reference' &&
        operationKind != 'stocktake_settle_reference') {
      throw const FormatException('Invalid lifecycle dependency output.');
    }
    if (allowedLifecycleOperationKinds != null &&
        !allowedLifecycleOperationKinds.contains(operationKind)) {
      throw const FormatException('Unexpected lifecycle dependency output.');
    }
  }
  return documentId;
}

bool _sameKeys(Map<String, Object?> data, Set<String> expected) =>
    data.length == expected.length && expected.every(data.containsKey);
