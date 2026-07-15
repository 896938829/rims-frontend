import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/auth/domain/services/auth_session_lifecycle_gate.dart';

void main() {
  test('serializes callers in arrival order', () async {
    final gate = AuthSessionLifecycleGate();
    final releaseFirst = Completer<void>();
    final firstStarted = Completer<void>();
    final events = <String>[];

    final first = gate.run(() async {
      events.add('first-start');
      firstStarted.complete();
      await releaseFirst.future;
      events.add('first-end');
    });
    await firstStarted.future;
    final second = gate.run(() async {
      events.add('second');
    });

    await Future<void>.delayed(Duration.zero);
    expect(events, ['first-start']);
    releaseFirst.complete();
    await Future.wait([first, second]);
    expect(events, ['first-start', 'first-end', 'second']);
  });

  test('allows nested lifecycle work in the same async zone', () async {
    final gate = AuthSessionLifecycleGate();

    final result = await gate
        .run(() => gate.run(() async => 'completed'))
        .timeout(const Duration(seconds: 1));

    expect(result, 'completed');
  });
}
