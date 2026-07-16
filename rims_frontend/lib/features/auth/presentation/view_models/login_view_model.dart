import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../../../../core/security/local_authenticator.dart';
import '../../domain/repositories/auth_repository.dart';
import '../../domain/repositories/local_unlock_repository.dart';
import '../../domain/repositories/second_factor_repository.dart';
import 'auth_session_controller.dart';

final class LoginViewModel extends ChangeNotifier {
  LoginViewModel({
    required this.authRepository,
    required this.sessionController,
    this.localUnlockCoordinator,
    this.unlockedCredentialSessionRepository,
  });

  final AuthRepository authRepository;
  final AuthSessionController sessionController;
  final LocalUnlockCoordinator? localUnlockCoordinator;
  final UnlockedCredentialSessionRepository?
  unlockedCredentialSessionRepository;

  String _username = '';
  String _password = '';
  bool _isLoading = false;
  String? _errorMessage;
  bool _isDisposed = false;
  int _generation = 0;
  AuthLoginAttempt? _activeLoginAttempt;
  SecondFactorLoginChallenge? _pendingSecondFactorChallenge;

  String get title => 'RIMS';
  String get subtitle => '零售端智能库存管理系统';
  String get warehouseHint => '登录后查看当前仓库、库存预警和业务单据';
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get canUseBiometricUnlock =>
      localUnlockCoordinator != null &&
      unlockedCredentialSessionRepository != null;

  SecondFactorLoginChallenge? takeSecondFactorChallenge() {
    final challenge = _pendingSecondFactorChallenge;
    _pendingSecondFactorChallenge = null;
    return challenge;
  }

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

    final attempt = sessionController.createLoginAttempt();
    _activeLoginAttempt = attempt;
    try {
      final result = await sessionController.beginLogin(
        authRepository: authRepository,
        username: username,
        password: password,
        attempt: attempt,
      );
      if (!_isCurrent(generation)) return false;
      _isLoading = false;
      return switch (result) {
        Success<AuthLoginStart>(data: AuthLoginCompleted()) =>
          _completeSuccess(),
        Success<AuthLoginStart>(
          data: AuthLoginChallengeRequired(challenge: final challenge),
        ) =>
          _showSecondFactorChallenge(challenge),
        FailureResult<AuthLoginStart>(failure: final failure) => _showFailure(
          failure,
        ),
      };
    } on Object catch (_) {
      if (!_isCurrent(generation)) return false;
      _isLoading = false;
      _errorMessage = '登录失败，请重试';
      _notifyListeners();
      return false;
    } finally {
      if (identical(_activeLoginAttempt, attempt)) {
        _activeLoginAttempt = null;
      }
    }
  }

  Future<bool> unlockWithBiometrics() async {
    final coordinator = localUnlockCoordinator;
    final repository = unlockedCredentialSessionRepository;
    if (_isDisposed ||
        _isLoading ||
        coordinator == null ||
        repository == null) {
      return false;
    }
    final generation = ++_generation;
    _isLoading = true;
    _errorMessage = null;
    _notifyListeners();
    try {
      final result = await sessionController.unlockWithBiometrics(
        coordinator: coordinator,
        repository: repository,
      );
      if (!_isCurrent(generation)) return false;
      _isLoading = false;
      return result.when(
        success: (_) => _completeSuccess(),
        failure: _showFailure,
      );
    } on Object {
      if (!_isCurrent(generation)) return false;
      _isLoading = false;
      _errorMessage = '本机解锁失败，请使用账号和密码登录';
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

  bool _showSecondFactorChallenge(SecondFactorLoginChallenge challenge) {
    final previous = _pendingSecondFactorChallenge;
    _pendingSecondFactorChallenge = challenge;
    if (previous != null) unawaited(previous.cancel());
    _errorMessage = null;
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
    _activeLoginAttempt?.cancel();
    _activeLoginAttempt = null;
    final challenge = _pendingSecondFactorChallenge;
    _pendingSecondFactorChallenge = null;
    if (challenge != null) unawaited(challenge.cancel());
    _password = '';
    _isLoading = false;
    super.dispose();
  }
}
