import 'package:flutter/foundation.dart';

import '../../../../core/result/result.dart';
import '../../domain/repositories/local_unlock_repository.dart';

final class BiometricUnlockViewModel extends ChangeNotifier {
  BiometricUnlockViewModel({required this.repository});

  final BiometricSettingsRepository repository;
  bool _enabled = false;
  bool _loading = false;
  bool _disposed = false;
  String? _errorMessage;
  int _generation = 0;

  bool get enabled => _enabled;
  bool get loading => _loading;
  String? get errorMessage => _errorMessage;

  Future<bool> load() =>
      _run(repository.isEnabled, onSuccess: (enabled) => _enabled = enabled);

  Future<bool> setEnabled(bool value) => _run(() async {
    final result = await repository.setEnabled(value);
    return result.when(
      success: (_) => Success(value),
      failure: FailureResult<bool>.new,
    );
  }, onSuccess: (enabled) => _enabled = enabled);

  Future<bool> _run(
    Future<Result<bool>> Function() operation, {
    required ValueChanged<bool> onSuccess,
  }) async {
    if (_disposed || _loading) return false;
    final generation = ++_generation;
    _loading = true;
    _errorMessage = null;
    _notify();
    try {
      final result = await operation();
      if (!_current(generation)) return false;
      return result.when(
        success: (value) {
          onSuccess(value);
          return true;
        },
        failure: (failure) {
          _errorMessage = failure.message;
          return false;
        },
      );
    } on Object {
      if (!_current(generation)) return false;
      _errorMessage = '操作失败，请重试';
      return false;
    } finally {
      if (_current(generation)) {
        _loading = false;
        _notify();
      }
    }
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation += 1;
    _loading = false;
    super.dispose();
  }
}
