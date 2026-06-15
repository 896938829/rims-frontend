import 'dart:async';

import 'app_event.dart';

final class AppEventBus {
  AppEventBus();

  final StreamController<AppEvent> _controller =
      StreamController<AppEvent>.broadcast();

  void publish(AppEvent event) {
    if (_controller.isClosed) {
      return;
    }

    _controller.add(event);
  }

  Stream<T> on<T extends AppEvent>() {
    return _controller.stream.where((event) => event is T).cast<T>();
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
