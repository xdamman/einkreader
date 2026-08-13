// Network failures must never surface as raw exception dumps: the screen
// says "you're offline", the debug log keeps the full details.
import 'dart:io';

import 'package:einkreader/services/app_log.dart';
import 'package:einkreader/services/errors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('connectivity failures read as offline, not as exception dumps', () {
    const raw = "ClientException with SocketException: Failed host lookup: "
        "'api.github.com' (OS Error: No address associated with hostname, "
        'errno = 7)';
    final message = friendlyError(raw, doing: 'checking for updates');
    expect(message, contains("You're offline"));
    expect(message, isNot(contains('SocketException')));
    expect(message, isNot(contains('api.github.com')));
  });

  test('unexpected errors point to the debug log', () {
    final message =
        friendlyError(StateError('boom'), doing: 'creating the backup');
    expect(message, contains('debug log'));
    expect(message, isNot(contains('boom')));
  });

  test('the full error is preserved in the debug log', () async {
    friendlyError(const SocketException('no route'), doing: 'refreshing');
    // _add is fire-and-forget; let it complete.
    await Future<void>.delayed(Duration.zero);
    final entries = await AppLogService.instance.entries();
    expect(entries.any((e) => e.message.contains('no route')), isTrue);
  });

  test('looksOffline recognizes the usual network failures', () {
    expect(looksOffline(const SocketException('x')), isTrue);
    expect(looksOffline('Feed: Failed host lookup: example.com'), isTrue);
    expect(looksOffline('Connection refused'), isTrue);
    expect(looksOffline('FormatException: bad xml'), isFalse);
  });
}
