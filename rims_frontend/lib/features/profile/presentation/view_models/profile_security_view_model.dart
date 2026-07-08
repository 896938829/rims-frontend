import 'package:flutter/foundation.dart';

import '../../../admin/domain/entities/admin_user.dart';
import '../../../admin/domain/repositories/admin_repository.dart';

final class ProfileSecurityViewModel extends ChangeNotifier {
  ProfileSecurityViewModel({this.repository});

  final AdminRepository? repository;

  bool _isChangingPassword = false;
  String? _passwordError;
  String? _passwordMessage;

  bool get isChangingPassword => _isChangingPassword;
  String? get passwordError => _passwordError;
  String? get passwordMessage => _passwordMessage;

  Future<bool> changePassword({
    required String oldPassword,
    required String newPassword,
    required String confirmPassword,
  }) async {
    if (_isChangingPassword) {
      return false;
    }

    final oldValue = oldPassword.trim();
    final newValue = newPassword.trim();
    final confirmValue = confirmPassword.trim();

    if (oldValue.isEmpty || newValue.isEmpty) {
      _passwordError = '请填写原密码和新密码';
      _passwordMessage = null;
      notifyListeners();
      return false;
    }

    if (newValue != confirmValue) {
      _passwordError = '两次输入的新密码不一致';
      _passwordMessage = null;
      notifyListeners();
      return false;
    }

    final repository = this.repository;
    if (repository == null) {
      _passwordError = '账号安全服务不可用';
      _passwordMessage = null;
      notifyListeners();
      return false;
    }

    _isChangingPassword = true;
    _passwordError = null;
    _passwordMessage = null;
    notifyListeners();

    var changed = false;
    final result = await repository.changeOwnPassword(
      ChangeOwnPasswordRequest(oldPassword: oldValue, newPassword: newValue),
    );
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

    _isChangingPassword = false;
    notifyListeners();
    return changed;
  }
}
