abstract class AppEvent {
  const AppEvent();
}

final class AuthStateChangedEvent extends AppEvent {
  const AuthStateChangedEvent({required this.isAuthenticated});

  final bool isAuthenticated;
}

final class TokenExpiredEvent extends AppEvent {
  const TokenExpiredEvent();
}

final class UserProfileUpdatedEvent extends AppEvent {
  const UserProfileUpdatedEvent();
}

final class GlobalRefreshRequestedEvent extends AppEvent {
  const GlobalRefreshRequestedEvent();
}

final class AccountOwnershipChangedEvent extends AppEvent {
  const AccountOwnershipChangedEvent({
    required this.previousAccountId,
    required this.currentAccountId,
  });

  final String? previousAccountId;
  final String? currentAccountId;
}

final class WarehouseOwnershipChangedEvent extends AppEvent {
  const WarehouseOwnershipChangedEvent({
    required this.accountId,
    required this.previousWarehouseId,
    required this.currentWarehouseId,
  });

  final String accountId;
  final int? previousWarehouseId;
  final int? currentWarehouseId;
}
