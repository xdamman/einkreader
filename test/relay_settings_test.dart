// The Nostr relay list: stored in preferences (defaults when empty), shown
// in Settings with a per-relay status and add/remove editing. Also covers
// the generalized outbox carrying signed Nostr events next to tweets.
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/services/nostr_service.dart';
import 'package:einkreader/services/outbox_service.dart';
import 'package:einkreader/services/profile_service.dart';
import 'package:einkreader/widgets/relay_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    AppDatabase.instance.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_relays').path,
        'test.db');
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    OutboxService.instance.debugNostrPublish = null;
    ProfileService.instance.debugPublish = null;
  });

  test('relays: defaults until edited; empty list falls back', () async {
    expect(await NostrService.relays(), NostrService.defaultRelays);
    await NostrService.saveRelays(['wss://my.relay']);
    expect(await NostrService.relays(), ['wss://my.relay']);
    await NostrService.saveRelays([]);
    expect(await NostrService.relays(), NostrService.defaultRelays);
  });

  testWidgets('settings section: explanation, status per relay, add/remove',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: RelaySettings(
            checker: (relay) async => relay != 'wss://nos.lol',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Relays are small independent servers'),
        findsOneWidget);
    for (final relay in NostrService.defaultRelays) {
      expect(find.text(relay), findsOneWidget);
    }
    // One default is down in this fake: shown as unreachable.
    expect(find.text('Not reachable right now'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsNWidgets(2));

    // Add a relay (validated), then remove it again.
    await tester.enterText(find.byType(TextField), 'https://not-a-relay');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('A relay address starts with wss://'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'wss://my.relay');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('wss://my.relay'), findsOneWidget);
    expect(await NostrService.relays(), contains('wss://my.relay'));

    await tester.tap(find.byTooltip('Remove relay').last);
    await tester.pumpAndSettle();
    expect((await NostrService.relays()), isNot(contains('wss://my.relay')));
  });

  test('outbox carries nostr events: queued on failure, flushed on success',
      () async {
    // A profile publish that no relay accepts lands in the outbox…
    await ProfileService.instance.createIdentity();
    ProfileService.instance.debugPublish = (event) async => 0;
    final accepted = await ProfileService.instance
        .saveProfile(const Profile(name: 'Xavier'));
    expect(accepted, 0);
    final queued = (await OutboxService.instance.items())
        .where((i) => i.kind == 'nostr')
        .toList();
    expect(queued, hasLength(1));
    expect(queued.single.text, 'Profile update');
    expect(queued.single.payload, contains('"kind":0'));

    // …and a later flush publishes the stored signed event verbatim.
    Map<String, dynamic>? republished;
    OutboxService.instance.debugNostrPublish = (event) async {
      republished = event;
      return 1;
    };
    final (sent, remaining) = await OutboxService.instance.flush();
    expect(sent, greaterThanOrEqualTo(1));
    expect(remaining, 0);
    expect(republished!['kind'], 0);
    expect(republished!['sig'], isNotEmpty);
  });
}
