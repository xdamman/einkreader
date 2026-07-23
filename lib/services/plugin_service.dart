import 'package:shared_preferences/shared_preferences.dart';

/// Plugins are the paid layer: einkreader itself is free forever; plugins
/// run on our servers (or third-party APIs) and need the supporter
/// subscription. Until Google Play billing ships, "early access" stands in
/// for a subscription — activated free from the pitch screen — so the whole
/// plugin machinery is real from day one.
class PluginService {
  PluginService._();
  static final PluginService instance = PluginService._();

  static const _kEarlyAccess = 'supporter_early_access';
  static const _kTwitterOn = 'plugin_twitter_on';
  static const _kEmailOn = 'plugin_email_on';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  /// Whether plugins are unlocked. Today: the free early-access flag; later:
  /// a verified Play subscription (or 5-year one-time purchase).
  Future<bool> get isSupporter async =>
      (await _prefs).getBool(_kEarlyAccess) ?? false;

  Future<void> activateEarlyAccess() async =>
      (await _prefs).setBool(_kEarlyAccess, true);

  Future<bool> get twitterOn async =>
      (await _prefs).getBool(_kTwitterOn) ?? false;

  Future<bool> get emailOn async => (await _prefs).getBool(_kEmailOn) ?? false;

  Future<void> setTwitterOn(bool on) async =>
      (await _prefs).setBool(_kTwitterOn, on);

  Future<void> setEmailOn(bool on) async =>
      (await _prefs).setBool(_kEmailOn, on);

  /// A plugin is active when unlocked AND toggled on.
  Future<bool> get twitterActive async =>
      await isSupporter && await twitterOn;

  Future<bool> get emailActive async => await isSupporter && await emailOn;
}
