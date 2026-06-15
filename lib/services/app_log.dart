import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class AppLogEntry {
  final DateTime time;
  final String level;
  final String message;

  const AppLogEntry({
    required this.time,
    required this.level,
    required this.message,
  });

  Map<String, Object?> toJson() => {
    'time': time.toIso8601String(),
    'level': level,
    'message': message,
  };

  static AppLogEntry fromJson(Map<String, Object?> json) => AppLogEntry(
    time:
        DateTime.tryParse(json['time'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    level: json['level'] as String? ?? 'info',
    message: json['message'] as String? ?? '',
  );
}

class AppLogService {
  AppLogService._();
  static final AppLogService instance = AppLogService._();

  static const developerModeKey = 'developer_mode';
  static const _logsKey = 'app_logs';
  static const _maxEntries = 400;

  final changes = StreamController<void>.broadcast(sync: true);

  Future<bool> isDeveloperModeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(developerModeKey) ?? false;
  }

  Future<void> setDeveloperModeEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(developerModeKey, enabled);
    await info('Developer mode ${enabled ? 'enabled' : 'disabled'}');
    changes.add(null);
  }

  Future<List<AppLogEntry>> entries() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_logsKey)?.map((raw) {
          try {
            return AppLogEntry.fromJson(
              jsonDecode(raw) as Map<String, Object?>,
            );
          } catch (_) {
            return AppLogEntry(
              time: DateTime.fromMillisecondsSinceEpoch(0),
              level: 'error',
              message: 'Could not decode log entry: $raw',
            );
          }
        }).toList() ??
        [];
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_logsKey);
    changes.add(null);
  }

  Future<void> debug(String message) => _add('debug', message);
  Future<void> info(String message) => _add('info', message);
  Future<void> warn(String message) => _add('warn', message);
  Future<void> error(String message) => _add('error', message);

  Future<void> _add(String level, String message) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(_logsKey) ?? [];
    current.add(
      jsonEncode(
        AppLogEntry(
          time: DateTime.now(),
          level: level,
          message: message,
        ).toJson(),
      ),
    );
    final trimmed =
        current.length > _maxEntries
            ? current.sublist(current.length - _maxEntries)
            : current;
    await prefs.setStringList(_logsKey, trimmed);
    changes.add(null);
  }
}
