import 'package:shared_preferences/shared_preferences.dart';

final class AppPreferences {
  const AppPreferences(this._preferences);

  static const String kLocaleKey = 'locale';
  static const String kThemeModeKey = 'theme_mode';

  final SharedPreferences _preferences;

  String? get locale => _preferences.getString(kLocaleKey);

  Future<bool> setLocale(String locale) {
    return _preferences.setString(kLocaleKey, locale);
  }

  String? get themeMode => _preferences.getString(kThemeModeKey);

  Future<bool> setThemeMode(String themeMode) {
    return _preferences.setString(kThemeModeKey, themeMode);
  }
}
