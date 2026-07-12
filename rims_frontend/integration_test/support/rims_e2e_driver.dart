import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const Duration _defaultTimeout = Duration(seconds: 12);
const Duration _pollInterval = Duration(milliseconds: 100);

Future<void> waitForKey(
  WidgetTester tester,
  Key key, {
  Duration timeout = _defaultTimeout,
}) async {
  await _waitUntil(
    tester,
    description: 'key $key',
    timeout: timeout,
    condition: () => find.byKey(key).evaluate().isNotEmpty,
  );
}

Future<void> tapAndSettle(
  WidgetTester tester,
  Key key, {
  Duration timeout = _defaultTimeout,
}) async {
  await waitForKey(tester, key, timeout: timeout);
  await tester.tap(find.byKey(key));
  await _settleBounded(tester, timeout: timeout);
}

Future<void> enterText(
  WidgetTester tester,
  Key key,
  String value, {
  Duration timeout = _defaultTimeout,
}) async {
  await waitForKey(tester, key, timeout: timeout);
  await tester.enterText(find.byKey(key), value);
  await tester.pump();
}

Future<void> scrollUntilVisible(
  WidgetTester tester,
  Key key, {
  Finder? scrollable,
  double delta = -300,
  Duration timeout = _defaultTimeout,
}) async {
  final target = find.byKey(key);
  final scrollTarget = scrollable ?? find.byType(Scrollable).last;
  final deadline = DateTime.now().add(timeout);
  while (target.hitTestable().evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      throw TestFailure(
        'Timed out scrolling to key $key. ${_visibleState(tester)}',
      );
    }
    if (scrollTarget.evaluate().isEmpty) {
      throw TestFailure(
        'No scrollable found for key $key. ${_visibleState(tester)}',
      );
    }
    await tester.drag(scrollTarget, Offset(0, delta));
    await tester.pump(_pollInterval);
  }
}

Future<void> expectText(
  WidgetTester tester,
  String text, {
  Duration timeout = _defaultTimeout,
}) async {
  await _waitUntil(
    tester,
    description: 'text "$text"',
    timeout: timeout,
    condition: () => find.text(text).evaluate().isNotEmpty,
  );
  expect(find.text(text), findsWidgets);
}

Future<T> screenshotOnFailure<T>(
  IntegrationTestWidgetsFlutterBinding binding,
  String name,
  Future<T> Function() body,
) async {
  try {
    return await body();
  } catch (_) {
    try {
      await binding.takeScreenshot(name);
    } catch (_) {
      // Preserve the original acceptance failure when screenshots are unavailable.
    }
    rethrow;
  }
}

Future<void> _waitUntil(
  WidgetTester tester, {
  required String description,
  required Duration timeout,
  required bool Function() condition,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TestFailure(
        'Timed out waiting for $description. ${_visibleState(tester)}',
      );
    }
    await tester.pump(_pollInterval);
  }
}

Future<void> _settleBounded(
  WidgetTester tester, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  do {
    if (DateTime.now().isAfter(deadline)) {
      throw TestFailure(
        'Timed out waiting for frames to settle. ${_visibleState(tester)}',
      );
    }
    await tester.pump(_pollInterval);
  } while (tester.binding.hasScheduledFrame);
}

String _visibleState(WidgetTester tester) {
  String? routeName;
  final keys = <String>[];
  for (final element
      in find.byWidgetPredicate((_) => true, skipOffstage: false).evaluate()) {
    final route = ModalRoute.of(element);
    routeName ??= route?.settings.name;
    final key = element.widget.key;
    if (key != null && keys.length < 20) keys.add(key.toString());
  }
  return 'route=${routeName ?? 'unknown'}, visibleKeys=${keys.join(', ')}';
}
