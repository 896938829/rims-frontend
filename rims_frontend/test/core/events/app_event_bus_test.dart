import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/events/app_event.dart';
import 'package:rims_frontend/core/events/app_event_bus.dart';

final class TestEvent extends AppEvent {
  const TestEvent(this.value);

  final String value;
}

final class OtherEvent extends AppEvent {
  const OtherEvent();
}

void main() {
  test('publishes events to typed subscribers', () async {
    final eventBus = AppEventBus();
    addTearDown(eventBus.dispose);

    final future = eventBus.on<TestEvent>().first;

    eventBus.publish(const TestEvent('ready'));

    final event = await future;
    expect(event.value, 'ready');
  });

  test('typed stream ignores other event types', () async {
    final eventBus = AppEventBus();
    addTearDown(eventBus.dispose);

    final events = <TestEvent>[];
    final subscription = eventBus.on<TestEvent>().listen(events.add);
    addTearDown(subscription.cancel);

    eventBus.publish(const OtherEvent());
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
  });
}
