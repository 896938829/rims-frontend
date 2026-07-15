import 'package:flutter/foundation.dart';

import '../../../admin/domain/entities/admin_user.dart';
import '../../../admin/domain/repositories/admin_repository.dart';

final class ProfileSecurityViewModel extends ChangeNotifier {
  ProfileSecurityViewModel({this.repository});

  final AdminRepository? repository;

  bool _isChangingPassword = false;
  String? _passwordError;
  String? _passwordMessage;
  bool _isDisposed = false;
  int _generation = 0;

  bool get isChangingPassword => _isChangingPassword;
  String? get passwordError => _passwordError;
  String? get passwordMessage => _passwordMessage;

  Future<bool> changePassword({
    required String oldPassword,
    required String newPassword,
    required String confirmPassword,
  }) async {
    if (_isDisposed || _isChangingPassword) {
      return false;
    }

    final oldValue = oldPassword;
    final newValue = newPassword;
    final confirmValue = confirmPassword;

    if (oldValue.isEmpty || newValue.isEmpty) {
      _passwordError = '请填写原密码和新密码';
      _passwordMessage = null;
      _notifyListeners();
      return false;
    }

    if (newValue.runes.length < 12) {
      _passwordError = '新密码至少需要12个字符';
      _passwordMessage = null;
      _notifyListeners();
      return false;
    }

    if (newValue.runes.length > 128) {
      _passwordError = '新密码最多允许128个字符';
      _passwordMessage = null;
      _notifyListeners();
      return false;
    }

    if (newValue != confirmValue) {
      _passwordError = '两次输入的新密码不一致';
      _passwordMessage = null;
      _notifyListeners();
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _passwordError = '账号安全服务不可用';
      _passwordMessage = null;
      _notifyListeners();
      return false;
    }

    final generation = ++_generation;
    _isChangingPassword = true;
    _passwordError = null;
    _passwordMessage = null;
    _notifyListeners();

    var changed = false;
    try {
      final result = await repository.changeOwnPassword(
        ChangeOwnPasswordRequest(oldPassword: oldValue, newPassword: newValue),
      );
      if (!_isCurrent(generation)) return false;
      result.when(
        success: (_) {
          _passwordError = null;
          _passwordMessage = '密码已更新';
          changed = true;
        },
        failure: (failure) {
          _passwordError = failure.message;
          _passwordMessage = null;
        },
      );
    } on Object {
      if (!_isCurrent(generation)) return false;
      _passwordError = '密码更新失败，请重试';
      _passwordMessage = null;
    } finally {
      if (_isCurrent(generation)) {
        _isChangingPassword = false;
        _notifyListeners();
      }
    }
    return changed;
  }

  bool _isCurrent(int generation) => !_isDisposed && generation == _generation;

  void _notifyListeners() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _generation += 1;
    _isChangingPassword = false;
    super.dispose();
  }
}
