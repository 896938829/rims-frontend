import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_cleanup_intent.dart';
import 'package:rims_frontend/features/offline/domain/entities/outbox_operation_output.dart';

void main() {
  test(
    'operation output recursively snapshots and freezes structured data',
    () {
      final step = <String, Object?>{'state': 'created'};
      final steps = <Object?>[step];
      final tags = <Object?>{'reviewed'};
      final metadata = <String, Object?>{'steps': steps, 'tags': tags};
      final source = <String, Object?>{'documentId': 91, 'metadata': metadata};

      final output = OutboxOperationOutput(version: 1, data: source);
      step['state'] = 'mutated';
      steps.add('late');
      tags.add('late');
      metadata['late'] = true;
      source['documentId'] = 999;

      expect(output.data, {
        'documentId': 91,
        'metadata': {
          'steps': [
            {'state': 'created'},
          ],
          'tags': {'reviewed'},
        },
      });
      final frozenMetadata = output.data['metadata']! as Map<String, Object?>;
      final frozenSteps = frozenMetadata['steps']! as List<Object?>;
      final frozenStep = frozenSteps.single! as Map<String, Object?>;
      final frozenTags = frozenMetadata['tags']! as Set<Object?>;
      expect(() => output.data['late'] = true, throwsUnsupportedError);
      expect(() => frozenMetadata['late'] = true, throwsUnsupportedError);
      expect(() => frozenSteps.add('late'), throwsUnsupportedError);
      expect(() => frozenStep['state'] = 'late', throwsUnsupportedError);
      expect(() => frozenTags.add('late'), throwsUnsupportedError);
    },
  );

  test('cleanup request and intent snapshot immutable request IDs', () {
    final requestIds = <String>['attachment-1'];
    final request = OutboxCleanupRequest(
      draftId: 'draft-1',
      attachmentRequestIds: requestIds,
    );
    final intentIds = <String>['attachment-2'];
    final intent = OutboxCleanupIntent(
      operationId: 'complete-1',
      accountId: '7',
      warehouseId: 11,
      draftId: 'draft-1',
      attachmentRequestIds: intentIds,
      createdAt: DateTime.utc(2026, 7, 13),
      updatedAt: DateTime.utc(2026, 7, 13),
    );

    requestIds.add('late-request');
    intentIds.add('late-intent');

    expect(request.attachmentRequestIds, ['attachment-1']);
    expect(intent.attachmentRequestIds, ['attachment-2']);
    expect(
      () => request.attachmentRequestIds.add('blocked'),
      throwsUnsupportedError,
    );
    expect(
      () => intent.attachmentRequestIds.add('blocked'),
      throwsUnsupportedError,
    );
  });
}
