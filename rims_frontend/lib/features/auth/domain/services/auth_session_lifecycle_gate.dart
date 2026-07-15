import 'dart:async';
import 'dart:collection';

/// Serializes authentication ownership transitions while allowing nested work
/// in the same asynchronous call chain.
final class AuthSessionLifecycleGate {
  final Queue<void Function()> _pending = Queue<void Function()>();
  bool _active = false;

  Future<T> run<T>(Future<T> Function() operation) {
    if (identical(Zone.current[this], this)) return operation();

    final result = Completer<T>();
    void execute() {
      () async {
        try {
          result.complete(
            await runZoned<Future<T>>(
              operation,
              zoneValues: <Object?, Object?>{this: this},
            ),
          );
        } on Object catch (error, stackTrace) {
          result.completeError(error, stackTrace);
        } finally {
          _pending.removeFirst();
          if (_pending.isEmpty) {
            _active = false;
          } else {
            _pending.first();
          }
        }
      }();
    }

    _pending.add(execute);
    if (!_active) {
      _active = true;
      execute();
    }
    return result.future;
  }
}
