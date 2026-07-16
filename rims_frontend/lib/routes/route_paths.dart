abstract final class RoutePaths {
  static const String login = '/';
  static const String secondFactorLogin = '/second-factor';
  static const String shell = '/app';
  static const String drafts = '/app/drafts';
  static const String syncCenter = '/app/sync';
  static const String deviceSessions = '/app/device-sessions';
  static const String secondFactorSettings = '/app/security/two-factor';

  static String openDraft(String draftId) =>
      Uri(path: shell, queryParameters: {'draft': draftId}).toString();
}
