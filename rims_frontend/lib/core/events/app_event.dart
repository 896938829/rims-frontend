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
