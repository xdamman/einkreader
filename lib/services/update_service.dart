import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// Result of checking GitHub for a newer release.
class UpdateInfo {
  /// Installed app version, e.g. "0.1.3".
  final String currentVersion;

  /// Latest released version (tag without a leading "v"), e.g. "0.1.4".
  final String latestVersion;

  /// Direct download URL for the release's .apk asset, if any.
  final String? apkUrl;

  /// The release page on GitHub (fallback when there's no apk asset).
  final String releaseUrl;

  final bool updateAvailable;

  const UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.apkUrl,
    required this.releaseUrl,
    required this.updateAvailable,
  });
}

/// Checks the GitHub Releases API for a newer build. There is no silent
/// self-update for a sideloaded app — this only surfaces the new version and a
/// direct download link; installing still goes through the system installer.
class UpdateService {
  static const repo = 'xdamman/einkreader';

  final http.Client _client;

  /// Overrides the installed version in tests (avoids the platform channel).
  final String? _currentVersionOverride;

  UpdateService({http.Client? client, String? currentVersion})
      : _client = client ?? http.Client(),
        _currentVersionOverride = currentVersion;

  Future<UpdateInfo?> check() async {
    final current =
        _currentVersionOverride ?? (await PackageInfo.fromPlatform()).version;
    final response = await _client.get(
      Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
    );
    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final tag = (data['tag_name'] as String?) ?? '';
    final latest = tag.startsWith('v') ? tag.substring(1) : tag;
    if (latest.isEmpty) return null;

    String? apkUrl;
    for (final asset in (data['assets'] as List?) ?? const []) {
      final name = (asset as Map)['name'] as String? ?? '';
      if (name.toLowerCase().endsWith('.apk')) {
        apkUrl = asset['browser_download_url'] as String?;
        break;
      }
    }

    return UpdateInfo(
      currentVersion: current,
      latestVersion: latest,
      apkUrl: apkUrl,
      releaseUrl: (data['html_url'] as String?) ??
          'https://github.com/$repo/releases/latest',
      updateAvailable: isVersionNewer(latest, current),
    );
  }
}

/// True when [latest] is a higher version than [current]. Compares dotted
/// numeric components ("0.2.0" > "0.1.9"), ignoring any "+build" suffix and
/// non-numeric noise. Pure function so it can be unit-tested without a device.
bool isVersionNewer(String latest, String current) {
  List<int> parts(String v) => v
      .split('+')
      .first
      .split('.')
      .map((s) => int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();

  final a = parts(latest);
  final b = parts(current);
  final length = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}
