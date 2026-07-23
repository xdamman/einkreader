// The opt-in public profile: locally-generated Nostr identity (backed up via
// SharedPreferences → Android Auto Backup) and profile metadata publishing.
import 'dart:convert';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/services/nostr_service.dart';
import 'package:einkreader/services/profile_service.dart';
import 'package:einkreader/screens/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
    final result = await service.publishHighlight(article, highlight);
    expect(result.eventId, published!['id']);
    expect(published!['kind'], 9802);
    expect(published!['content'], 'the passage');
    expect(published!['tags'],
        anyElement(equals(['r', 'https://example.com/story'])));
    expect(published!['tags'],
        anyElement(equals(['comment', 'my thought'])));
  });

  testWidgets('profile dialog: name-only creation, then the editor',
      (tester) async {
    ProfileService.instance.debugPublish = (event) async => 1;
    ProfileService.instance.debugHttpClient = MockClient(
        (request) async => http.Response(jsonEncode({'ok': true}), 200));
    await tester.pumpWidget(const MaterialApp(home: ProfileScreen()));
    await tester.pumpAndSettle();

    // Opt-in: short privacy copy plus a single name field. No Nostr jargon,
    // no key talk.
    expect(find.textContaining('private and local-first'), findsOneWidget);
    expect(find.text('Your name'), findsOneWidget);
    expect(find.textContaining('nsec'), findsNothing);
    expect(find.textContaining('npub'), findsNothing);
    expect(await ProfileService.instance.enabled, isFalse);

    await tester.enterText(
        find.widgetWithText(TextField, 'Your name'), 'Xavier');
    await tester.pump();
    // The username is auto-suggested from the name, editable, with the
    // domain shown as a suffix.
    expect(find.text('@einkreader.app'), findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Username'))
            .controller!
            .text,
        'xavier');
    await tester.ensureVisible(find.text('Create profile'));
    await tester.tap(find.text('Create profile'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(await ProfileService.instance.enabled, isTrue);
    expect((await ProfileService.instance.profile()).name, 'Xavier');
    expect(await ProfileService.instance.username, 'xavier');

    // Editor: tappable avatar invitation, the full address made obvious,
    // bio, links; still no key talk.
    expect(find.text('Tap the avatar to change it'), findsOneWidget);
    expect(find.text('xavier@einkreader.app'), findsOneWidget);
    expect(find.textContaining('tag you and'), findsOneWidget);
    expect(find.text('Short bio'), findsOneWidget);
    expect(find.text('Social links (one per line)'), findsOneWidget);
    expect(find.textContaining('secret key'), findsNothing);

    // Auto-save: editing then leaving the screen persists and publishes.
    await tester.enterText(
        find.widgetWithText(TextField, 'Short bio'), 'Reads on e-ink');
    final state =
        tester.state(find.byType(ProfileScreen)) as dynamic;
    await tester.runAsync(() => state.debugPersistForTest());
    expect((await ProfileService.instance.profile()).about, 'Reads on e-ink');
  });

  test('suggestUsername: valid, padded, capped', () {
    expect(ProfileService.suggestUsername('Xavier Damman'), 'xavierdamman');
    expect(ProfileService.suggestUsername('Bob'), 'bobreader');
    expect(ProfileService.suggestUsername('X Æ A-12'), 'xa12reader');
    expect(ProfileService.suggestUsername('a' * 30), 'a' * 20);
    for (final input in ['Xavier Damman', 'Bob', '@!']) {
      expect(
          ProfileService.usernameRule
              .hasMatch(ProfileService.suggestUsername(input)),
          isTrue,
          reason: 'suggestion for "$input" must always be valid');
    }
  });

  test('registerUsername: success, taken, and offline-pending', () async {
    final service = ProfileService.instance;
    await service.createIdentity();
    final pubkey = await service.publicKeyHex;

    // Success: POSTs a signed proof, stores the name for the nip05 address.
    service.debugHttpClient = MockClient((request) async {
      expect(request.url.toString(), 'https://einkreader.app/api/register');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['name'], 'xavier');
      expect(body['pubkey'], pubkey);
      final event = body['event'] as Map<String, dynamic>;
      expect(event['kind'], 27235);
      expect(event['content'], 'xavier');
      expect(
          bip340.verify(event['pubkey'] as String, event['id'] as String,
              event['sig'] as String),
          isTrue);
      return http.Response(
          jsonEncode({'ok': true, 'nip05': 'xavier@einkreader.app'}), 200);
    });
    expect(await service.registerUsername('xavier'), isTrue);
    expect(await service.username, 'xavier');
    expect(await service.nip05Address, 'xavier@einkreader.app');

    // The published kind-0 metadata carries the address.
    Map<String, dynamic>? published;
    service.debugPublish = (event) async {
      published = event;
      return 1;
    };
    await service.saveProfile(const Profile(name: 'Xavier'));
    expect(jsonDecode(published!['content'] as String)['nip05'],
        'xavier@einkreader.app');

    // Taken: surfaces so the user can pick another.
    service.debugHttpClient = MockClient((request) async =>
        http.Response(jsonEncode({'error': 'Username is taken'}), 409));
    await expectLater(service.registerUsername('someone'),
        throwsA(isA<UsernameTakenException>()));

    // Bad format never reaches the network.
    await expectLater(service.registerUsername('abc'), throwsFormatException);

    service.debugHttpClient = null;
  });

  test('offline registration stays pending and retries on save', () async {
    final service = ProfileService.instance;
    await service.createIdentity();
    service.debugPublish = (event) async => 1;

    var online = false;
    service.debugHttpClient = MockClient((request) async {
      if (!online) throw Exception('offline');
      return http.Response(jsonEncode({'ok': true}), 200);
    });
    expect(await service.registerUsername('xavier'), isFalse);
    expect(await service.username, isNull);
    expect(await service.pendingUsername, 'xavier');
    expect(await service.nip05Address, 'xavier@einkreader.app',
        reason: 'the address is shown even while pending');

    // Back online: the next profile save completes the registration.
    online = true;
    await service.saveProfile(const Profile(name: 'Xavier'));
    expect(await service.username, 'xavier');
    expect(await service.pendingUsername, isNull);
    service.debugHttpClient = null;
  });

  test('uploadAvatar: Blossom PUT with signed authorization', () async {
    final service = ProfileService.instance;
    await service.createIdentity();
    final bytes = Uint8List.fromList(List.generate(64, (i) => i));
    final hash = sha256.convert(bytes).toString();

    service.debugHttpClient = MockClient((request) async {
      expect(request.method, 'PUT');
      expect(request.url.toString(),
          '${ProfileService.blossomServer}/upload');
      expect(request.bodyBytes, bytes);
      final authHeader = request.headers['Authorization']!;
      expect(authHeader, startsWith('Nostr '));
      final auth = jsonDecode(
              utf8.decode(base64Decode(authHeader.substring(6))))
          as Map<String, dynamic>;
      expect(auth['kind'], 24242);
      expect(auth['tags'], anyElement(equals(['t', 'upload'])));
      expect(auth['tags'], anyElement(equals(['x', hash])));
      expect(
          bip340.verify(auth['pubkey'] as String, auth['id'] as String,
              auth['sig'] as String),
          isTrue);
      return http.Response(
          jsonEncode({'url': '${ProfileService.blossomServer}/$hash.jpg'}),
          200);
    });
    final url = await service.uploadAvatar(bytes);
    expect(url, '${ProfileService.blossomServer}/$hash.jpg');
    service.debugHttpClient = null;
  });
}
