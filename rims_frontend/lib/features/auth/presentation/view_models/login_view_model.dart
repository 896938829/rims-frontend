import 'package:flutter/foundation.dart';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../domain/repositories/auth_repository.dart';
import 'auth_session_controller.dart';

final class LoginViewModel extends ChangeNotifier {
  LoginViewModel({
    required this.authRepository,
    required this.sessionController,
  });

  final AuthRepository authRepository;
  final AuthSessionController sessionController;

  String _username = '';
  String _password = '';
  bool _isLoading = false;
  String? _errorMessage;
  bool _isDisposed = false;
  int _generation = 0;

  String get title => 'RIMS';
  String get subtitle => '零售端智能库存管理系统';
  String get warehouseHint => '登录后查看当前仓库、库存预警和业务单据';
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  void updateUsername(String value) {
    if (_isDisposed) return;
    _username = value;
    if (_errorMessage != null) {
      _errorMessage = null;
      notifyListeners();
    }
  }

  void updatePassword(String value) {
    if (_isDisposed) return;
    _password = value;
    if (_errorMessage != null) {
      _errorMessage = null;
      notifyListeners();
    }
  }

  Future<bool> login() async {
    if (_isDisposed || _isLoading) return false;
    final generation = ++_generation;
    final username = _username.trim();
    final password = _password;
    _password = '';

    if (username.isEmpty || password.isEmpty) {
      _errorMessage = '请输入账号和密码';
      _notifyListeners();
      return false;
    }
    if (password.runes.length > 128) {
      _errorMessage = '密码最多允许128个字符';
      _notifyListeners();
      return false;
    }

    _isLoading = true;
    _errorMessage = null;
    _notifyListeners();

    try {
      final result = await sessionController.login(
        authRepository: authRepository,
        username: username,
        password: password,
      );
      if (!_isCurrent(generation)) return false;
      _isLoading = false;
      return switch (result) {
        Success<void>() => _completeSuccess(),
        FailureResult<void>(failure: final failure) => _showFailure(failure),
      };
    } on Object catch (_) {
      if (!_isCurrent(generation)) return false;
      _isLoading = false;
      _errorMessage = '登录失败，请重试';
      _notifyListeners();
      return false;
    }
  }

  bool _completeSuccess() {
    _notifyListeners();
    return true;
  }

  bool _showFailure(Failure failure) {
    _errorMessage = failure.message;
    _notifyListeners();
    return false;
  }

  bool _isCurrent(int generation) => !_isDisposed && generation == _generation;

  void _notifyListeners() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _generation += 1;
    _password = '';
    _isLoading = false;
    super.dispose();
  }
}
