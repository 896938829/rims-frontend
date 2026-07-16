import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../core/result/result.dart';
import '../../../../core/result/failure.dart';
import '../../domain/entities/second_factor.dart';
import '../../domain/repositories/second_factor_repository.dart';

final class TwoFactorViewModel extends ChangeNotifier {
  TwoFactorViewModel.management({required this.repository})
    : _loginChallenge = null;

  TwoFactorViewModel.login({required SecondFactorLoginChallenge challenge})
    : repository = null,
      _loginChallenge = challenge;

  final SecondFactorRepository? repository;
  final SecondFactorLoginChallenge? _loginChallenge;

  SecondFactorStatus? _status;
  TOTPEnrollment? _enrollment;
  List<String> _recoveryCodes = const [];
  String _code = '';
  String _recoveryCode = '';
  String _password = '';
  String? _errorMessage;
  bool _isLoading = false;
  bool _useRecoveryCode = false;
  bool _loginCompleted = false;
  bool _challengeTerminated = false;
  bool _disposed = false;
  int _generation = 0;

  SecondFactorStatus? get status => _status;
  TOTPEnrollment? get enrollment => _enrollment;
  List<String> get recoveryCodes => List.unmodifiable(_recoveryCodes);
  String get code => _code;
  String get recoveryCode => _recoveryCode;
  String get password => _password;
  String? get errorMessage => _errorMessage;
  bool get isLoading => _isLoading;
  bool get isLoginChallenge => _loginChallenge != null;
  bool get challengeTerminated => _challengeTerminated;
  DateTime? get challengeExpiresAt => _loginChallenge?.expiresAt;
  bool get useRecoveryCode => _useRecoveryCode;
  set useRecoveryCode(bool value) {
    if (_disposed || _useRecoveryCode == value) return;
    _useRecoveryCode = value;
    _code = '';
    _recoveryCode = '';
    _errorMessage = null;
    _notify();
  }

  void updateCode(String value) {
    if (!_disposed) _code = value.trim();
  }

  void updateRecoveryCode(String value) {
    if (!_disposed) _recoveryCode = value.trim();
  }

  void updatePassword(String value) {
    if (!_disposed) _password = value;
  }

  Future<bool> loadStatus() => _run<SecondFactorStatus>(
    _requireRepository().getStatus,
    onSuccess: (value) => _status = value,
  );

  Future<bool> beginEnrollment() => _run<TOTPEnrollment>(
    _requireRepository().beginEnrollment,
    onSuccess: (value) => _enrollment = value,
  );

  Future<bool> confirmEnrollment() async {
    if (!_validCode(_code)) return _validationFailure('请输入6位验证码');
    final submitted = _code;
    final success = await _run<RecoveryCodeSet>(
      () => _requireRepository().confirmEnrollment(submitted),
      onSuccess: (value) {
        _recoveryCodes = List.unmodifiable(value.codes);
        _enrollment = null;
        _status = SecondFactorStatus(
          enabled: true,
          pending: false,
          recoveryCodesRemaining: value.codes.length,
        );
      },
    );
    _code = '';
    return success;
  }

  Future<bool> regenerateRecoveryCodes() async {
    final proof = _proof();
    if (proof == null) return _validationFailure('请输入密码和一个验证因子');
    final success = await _run<RecoveryCodeSet>(
      () => _requireRepository().regenerateRecoveryCodes(proof),
      onSuccess: (value) {
        _recoveryCodes = List.unmodifiable(value.codes);
        _status = SecondFactorStatus(
          enabled: true,
          pending: false,
          recoveryCodesRemaining: value.codes.length,
        );
      },
    );
    _clearProof();
    return success;
  }

  Future<bool> disable() async {
    final proof = _proof();
    if (proof == null) return _validationFailure('请输入密码和一个验证因子');
    final success = await _run<void>(
      () => _requireRepository().disable(proof),
      onSuccess: (_) {
        _status = const SecondFactorStatus(
          enabled: false,
          pending: false,
          recoveryCodesRemaining: 0,
        );
        _enrollment = null;
        _recoveryCodes = const [];
      },
    );
    _clearProof();
    return success;
  }

  Future<bool> completeLogin() async {
    final challenge = _loginChallenge;
    if (challenge == null || _loginCompleted) return false;
    final code = _code;
    final recoveryCode = _recoveryCode;
    if (_useRecoveryCode) {
      if (!_validRecoveryCode(recoveryCode)) {
        return _validationFailure('请输入有效的恢复代码');
      }
    } else if (!_validCode(code)) {
      return _validationFailure('请输入6位验证码');
    }
    final success = await _run<void>(
      () => challenge.complete(
        code: _useRecoveryCode ? null : code,
        recoveryCode: _useRecoveryCode ? recoveryCode : null,
      ),
      onSuccess: (_) => _loginCompleted = true,
    );
    _code = '';
    _recoveryCode = '';
    return success;
  }

  void acknowledgeRecoveryCodes() {
    if (_disposed) return;
    _recoveryCodes = const [];
    _notify();
  }

  SecondFactorProof? _proof() {
    final hasCode = _validCode(_code);
    final hasRecovery = _validRecoveryCode(_recoveryCode);
    if (_password.isEmpty || hasCode == hasRecovery) return null;
    return SecondFactorProof(
      password: _password,
      code: hasCode ? _code : '',
      recoveryCode: hasRecovery ? _recoveryCode : '',
    );
  }

  Future<bool> _run<T>(
    Future<Result<T>> Function() action, {
    required void Function(T value) onSuccess,
  }) async {
    if (_disposed || _isLoading) return false;
    final generation = ++_generation;
    _isLoading = true;
    _errorMessage = null;
    _notify();
    try {
      final result = await action();
      if (!_current(generation)) return false;
      return result.when(
        success: (value) {
          onSuccess(value);
          _errorMessage = null;
          return true;
        },
        failure: (failure) {
          _errorMessage = failure.message;
          if (failure is SecondFactorChallengeTerminatedFailure) {
            _challengeTerminated = true;
          }
          return false;
        },
      );
    } on Object {
      if (!_current(generation)) return false;
      _errorMessage = '操作失败，请重试';
      return false;
    } finally {
      if (_current(generation)) {
        _isLoading = false;
        _notify();
      }
    }
  }

  bool _validationFailure(String message) {
    _errorMessage = message;
    _notify();
    return false;
  }

  void _clearProof() {
    _password = '';
    _code = '';
    _recoveryCode = '';
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  bool _validCode(String value) => RegExp(r'^\d{6}$').hasMatch(value);
  bool _validRecoveryCode(String value) =>
      value.replaceAll(RegExp(r'[\s-]'), '').length == 26;
  SecondFactorRepository _requireRepository() {
    final value = repository;
    if (value == null) {
      throw StateError('Second-factor management is unavailable.');
    }
    return value;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation += 1;
    _isLoading = false;
    _code = '';
    _recoveryCode = '';
    _password = '';
    _enrollment = null;
    _recoveryCodes = const [];
    final challenge = _loginChallenge;
    if (challenge != null) unawaited(challenge.cancel());
    super.dispose();
  }
}
