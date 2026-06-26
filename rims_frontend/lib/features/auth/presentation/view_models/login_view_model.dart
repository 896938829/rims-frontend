import 'package:flutter/foundation.dart';

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

  String get title => 'RIMS';
  String get subtitle => '零售端智能库存管理系统';
  String get warehouseHint => '登录后查看当前仓库、库存预警和业务单据';
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  void updateUsername(String value) {
    _username = value;
    if (_errorMessage != null) {
      _errorMessage = null;
      notifyListeners();
    }
  }

  void updatePassword(String value) {
    _password = value;
    if (_errorMessage != null) {
      _errorMessage = null;
      notifyListeners();
    }
  }

  Future<bool> login() async {
    final username = _username.trim();
    final password = _password;

    if (username.isEmpty || password.isEmpty) {
      _errorMessage = '请输入账号和密码';
      notifyListeners();
      return false;
    }

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    final result = await authRepository.login(
      username: username,
      password: password,
    );

    _isLoading = false;

    return result.when(
      success: (session) {
        sessionController.startSession(session);
        notifyListeners();
        return true;
      },
      failure: (failure) {
        _errorMessage = failure.message;
        notifyListeners();
        return false;
      },
    );
  }
}
