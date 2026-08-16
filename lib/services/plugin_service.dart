import 'package:shared_preferences/shared_preferences.dart';

/// Plugins add sources or channels to share content (Twitter, Email); they
/// run on our servers or third-party APIs and are toggled per device.
class PluginService {
  PluginService._();
  static final PluginService instance = PluginService._();

  static const _kTwitterOn = 'plugin_twitter_on';
  static const _kEmailOn = 'plugin_email_on';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<bool> get twitterOn async =>
      (await _prefs).getBool(_kTwitterOn) ?? false;

  Future<bool> get emailOn async => (await _prefs).getBool(_kEmailOn) ?? false;

  Future<void> setTwitterOn(bool on) async =>
      (await _prefs).setBool(_kTwitterOn, on);

  Future<void> setEmailOn(bool on) async =>
      (await _prefs).setBool(_kEmailOn, on);

  /// A plugin is active when toggled on.
  Future<bool> get twitterActive => twitterOn;

  Future<bool> get emailActive => emailOn;
}
