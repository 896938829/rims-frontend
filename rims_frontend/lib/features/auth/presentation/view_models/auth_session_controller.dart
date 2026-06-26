import 'package:flutter/foundation.dart';

import '../../domain/entities/app_user.dart';
import '../../domain/entities/auth_session.dart';
import '../../domain/entities/warehouse.dart';

final class AuthSessionController extends ChangeNotifier {
  AuthSession? _session;

  AuthSession? get session => _session;
  AppUser? get currentUser => _session?.user;
  Warehouse? get currentWarehouse => _session?.currentWarehouse;
  List<Warehouse> get warehouses => _session?.warehouses ?? const [];
  String? get accessToken => _session?.accessToken;
  bool get isAuthenticated => _session != null;

  void startSession(AuthSession session) {
    _session = session;
    notifyListeners();
  }

  void logout() {
    if (_session == null) {
      return;
    }

    _session = null;
    notifyListeners();
  }
}
