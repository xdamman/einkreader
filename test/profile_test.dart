// The opt-in public profile: locally-generated Nostr identity (backed up via
// SharedPreferences → Android Auto Backup), profile metadata publishing, and
// the private-by-default highlight compose flow.
import 'dart:convert';

import 'package:bip340/bip340.dart' as bip340;
import 'package:einkreader/models.dart';
import 'package:einkreader/services/nostr_service.dart';
import 'package:einkreader/services/profile_service.dart';
import 'package:einkreader/widgets/highlight_compose.dart';
import 'package:einkreader/widgets/profile_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ProfileService.instance.debugPublish = null;
  });

  test('bech32 encode round-trips with the existing decoder', () {
    final bytes = List.generate(32, (i) => (i * 7 + 3) & 0xff);
    final npub = NostrService.bech32Encode('npub', bytes);
    expect(npub, startsWith('npub1'));
    final hex = NostrService.decodeNpub(npub);
    expect(hex,
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
  });

  test('identity: opt-in creates keys once; events verify', () async {
    final service = ProfileService.instance;
    expect(await service.enabled, isFalse);
    await service.createIdentity();
    expect(await service.enabled, isTrue);
    final npub = await service.npub;
    final nsec = await service.nsec;
    expect(npub, startsWith('npub1'));
    expect(nsec, startsWith('nsec1'));
    // Idempotent: a second call keeps the same identity.
    await service.createIdentity();
    expect(await service.npub, npub);

    final event = await service.signEvent(kind: 1, content: 'hello');
    expect(event['pubkey'], await service.publicKeyHex);
    expect(
        bip340.verify(
            event['pubkey'] as String, event['id'] as String,
            event['sig'] as String),
        isTrue);
  });

  test('saveProfile publishes kind-0 metadata', () async {
    final service = ProfileService.instance;
    await service.createIdentity();
    Map<String, dynamic>? published;
    service.debugPublish = (event) async {
      published = event;
      return 2;
    };
    final accepted = await service.saveProfile(const Profile(
      name: 'Xavier',
      about: 'Reads on e-ink',
      picture: 'https://example.com/me.jpg',
      links: 'https://xavier.example\nhttps://twitter.com/xdamman',
    ));
    expect(accepted, 2);
    expect(published!['kind'], 0);
    final content = jsonDecode(published!['content'] as String) as Map;
    expect(content['name'], 'Xavier');
    expect(content['about'], 'Reads on e-ink');
    expect(content['picture'], 'https://example.com/me.jpg');
    expect(content['website'], 'https://xavier.example');
    expect(published!['tags'],
        anyElement(equals(['r', 'https://twitter.com/xdamman'])));
    // Fields persist locally regardless of publishing.
    expect((await service.profile()).name, 'Xavier');
  });

  test('publishHighlight is a NIP-84 highlight with comment tag', () async {
    final service = ProfileService.instance;
    await service.createIdentity();
    Map<String, dynamic>? published;
    service.debugPublish = (event) async {
      published = event;
      return 1;
    };
    const article = Article(
        sourceId: 1,
        guid: 'g',
        title: 'A Story',
        url: 'https://example.com/story',
        createdAt: 0);
    const highlight = Highlight(
        articleId: 1,
        text: 'the passage',
        comment: 'my thought',
        createdAt: 0);
    await service.publishHighlight(article, highlight);
    expect(published!['kind'], 9802);
    expect(published!['content'], 'the passage');
    expect(published!['tags'],
        anyElement(equals(['r', 'https://example.com/story'])));
    expect(published!['tags'],
        anyElement(equals(['comment', 'my thought'])));
  });

  group('HighlightComposeDialog', () {
    Future<HighlightComposeResult?> run(WidgetTester tester,
        {required bool profileEnabled,
        required bool twitterConnected,
        required Future<void> Function(WidgetTester) interact}) async {
      HighlightComposeResult? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: OutlinedButton(
                onPressed: () async {
                  result = await HighlightComposeDialog.show(context,
                      selection: 'the selected passage',
                      profileEnabled: profileEnabled,
                      twitterConnected: twitterConnected);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await interact(tester);
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('defaults to a private note (no toggles without profile)',
        (tester) async {
      final result = await run(tester,
          profileEnabled: false,
          twitterConnected: true, interact: (tester) async {
        expect(find.text('the selected passage'), findsOneWidget);
        expect(find.text('Share to profile'), findsNothing);
        await tester.enterText(
            find.byType(TextField), 'a private thought');
        await tester.tap(find.text('Save'));
      });
      expect(result!.comment, 'a private thought');
      expect(result.shareToProfile, isFalse);
      expect(result.shareToTwitter, isFalse);
    });

    testWidgets('share toggle reveals the Twitter cross-post toggle',
        (tester) async {
      final result = await run(tester,
          profileEnabled: true,
          twitterConnected: true, interact: (tester) async {
        expect(find.text('Also share on Twitter'), findsNothing);
        await tester.tap(find.text('Share to profile'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Also share on Twitter'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save & share'));
      });
      expect(result!.shareToProfile, isTrue);
      expect(result.shareToTwitter, isTrue);
    });
  });

  testWidgets('profile dialog: opt-in first, then the editor', (tester) async {
    ProfileService.instance.debugPublish = (event) async => 1;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: OutlinedButton(
              onPressed: () => ProfileDialog.show(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Opt-in: privacy-first copy, nothing created yet.
    expect(find.textContaining('private and local-first'), findsOneWidget);
    expect(find.textContaining('you stay in control'), findsOneWidget);
    expect(await ProfileService.instance.enabled, isFalse);

    await tester.tap(find.text('Create public profile'));
    await tester.pumpAndSettle();
    expect(await ProfileService.instance.enabled, isTrue);

    // Editor with the backup note.
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Short bio'), findsOneWidget);
    expect(find.text('Avatar image URL'), findsOneWidget);
    expect(find.textContaining("Android's standard app backup"),
        findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Name'), 'Xavier');
    await tester.tap(find.text('Save & publish'));
    await tester.pumpAndSettle();
    expect((await ProfileService.instance.profile()).name, 'Xavier');
  });
}
