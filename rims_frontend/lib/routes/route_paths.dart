abstract final class RoutePaths {
  static const String login = '/';
  static const String shell = '/app';
  static const String drafts = '/app/drafts';

  static String openDraft(String draftId) =>
      Uri(path: shell, queryParameters: {'draft': draftId}).toString();
}
