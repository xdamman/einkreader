// Feedback threads: who reacted (long press on a reaction), @mentions
// while replying, mention chips, images side by side and the image viewer,
// images added to new feedback, and replying offline. Run:
//
//   flutter test test/screenshots/feedback_shot_test.dart \
//     --update-goldens --dart-define=screenshots=true
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/screens/feedback_screen.dart';
import 'package:einkreader/screens/nostr_profile_screen.dart';
import 'package:einkreader/services/feedback_service.dart';
import 'package:einkreader/services/nostr_service.dart';
import 'package:einkreader/services/outbox_service.dart';
import 'package:einkreader/services/profile_service.dart';
import 'package:einkreader/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _enabled = bool.fromEnvironment('screenshots');

const _marie =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _agent =
    '735beae7899fa8c1ebe0e81087aeae773d37fba3f189f2c2e7808c7e1387b58f';
const _ana = '3333333333333333333333333333333333333333333333333333333333333333';

/// Answers from what it was given; publishing succeeds unless [offline].
class _Relay extends NostrService {
  final events = <Map<String, dynamic>>[];
  bool offline = false;

  @override
  Future<int> publish(Map<String, dynamic> event,
      {Duration timeout = const Duration(seconds: 8)}) async {
    if (offline) return 0;
    events.add(event);
    return 1;
  }

  @override
  Future<List<Map<String, dynamic>>> query(Map<String, dynamic> filter,
          {Duration timeout = const Duration(seconds: 8)}) async =>
      events
          .where((e) => (filter['kinds'] as List?)?.contains(e['kind']) ?? true)
          .toList();

  @override
  Future<Map<String, NostrProfile>> fetchProfiles(
          Iterable<String> hexPubkeys) async =>
      {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Relay relay;
  late FeedbackService service;
  late FeedbackNote root;
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  setUpAll(() async {
    if (!_enabled) return;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    AppDatabase.instance.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_feedback_shot').path,
        'test.db');
    await _loadFonts();
    relay = _Relay();
    service = FeedbackService(nostr: relay);
    await ProfileService.instance.createIdentity();
    final me = (await service.myPubkey)!;
    for (final (key, name) in [
      (me, 'Xavier'),
      (_marie, 'Marie'),
      (_agent, "Xavier's agent"),
      (_ana, 'Ana'),
    ]) {
      NostrProfileCache.debugPut(
          NostrProfile(pubkey: key, name: name, about: ''));
    }
    Map<String, dynamic> event(String id, String pubkey, int ago, int kind,
            String content, List<List<String>> tags) =>
        {
          'id': id,
          'pubkey': pubkey,
          'created_at': now - ago,
          'kind': kind,
          'tags': tags,
          'content': content,
        };
    final rootId = 'a' * 64;
    relay.events.addAll([
      event(rootId, _marie, 26 * 3600, 1,
          'Could I rename a feed? Some default names are too long.', [
        ['p', FeedbackService.officialHex],
        ['t', 'feedback'],
        ['t', 'feature-request'],
      ]),
      event('c' * 64, _ana, 3 * 3600, 1,
          'Tables from Substack posts show as raw text.', [
        ['p', FeedbackService.officialHex],
        ['t', 'feedback'],
        ['t', 'bug'],
        ['t', 'rendering-issue'],
      ]),
      event('d' * 64, _marie, 50 * 3600, 1,
          'The app crashed when I opened an empty folder.', [
        ['p', FeedbackService.officialHex],
        ['t', 'feedback'],
        ['t', 'bug'],
      ]),
      event('b' * 64, _agent, 5 * 3600, 1,
          'Proposal: rename any source from its ⋮ menu in Sources.', [
        ['e', rootId, '', 'root'],
        ['p', _marie],
      ]),
      for (final (who, ago, emoji) in [
        (_marie, 3 * 3600, '👍'),
        (me, 2 * 3600, '👍'),
        (_ana, 40 * 60, '👍'),
        (_ana, 35 * 60, '🎉'),
      ])
        event('$who$ago', who, ago, 7, emoji, [
          ['e', 'b' * 64]
        ]),
    ]);
    root = FeedbackNote.fromEvent(relay.events.first);
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(412, 915) * 2.0;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  Widget app() => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _withEmoji(buildEinkTheme()),
      home: FeedbackThreadScreen(root: root, service: service));

  testWidgets('who reacted', (tester) async {
    phone(tester);
    await tester.pumpWidget(app());
    await settle(tester);
    await tester.longPress(find.text('👍 3'));
    await settle(tester);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/feedback_1_who_reacted.png'));
  }, skip: !_enabled);

  testWidgets('mentioning while replying', (tester) async {
    phone(tester);
    await tester.pumpWidget(app());
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Looks good, @ei');
    await tester.pump();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/feedback_2_mention_suggestions.png'));
    await tester.tap(find.text('einkReader agent').last);
    await tester.pump();
    await tester.enterText(find.byType(TextField),
        "Looks good, @einkReader agent can it also reset to the feed's name?");
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/feedback_3_mention_sent.png'));
  }, skip: !_enabled);

  testWidgets('feedback kinds as filters', (tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _withEmoji(buildEinkTheme()),
        home: FeedbackScreen(service: service)));
    await settle(tester);
    await tester.tap(find.text('Bug 2'));
    await settle(tester);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/feedback_4_filters.png'));
  }, skip: !_enabled);

  testWidgets('mention chips and images side by side', (tester) async {
    phone(tester);
    final pages = [for (var i = 0; i < 3; i++) _fakePage(i)];
    noteImageProvider = (url) => MemoryImage(pages[int.parse(
        RegExp(r'(\d)\.png').firstMatch(url)!.group(1)!)]);
    addTearDown(() => noteImageProvider = NetworkImage.new);
    final ana = NostrService.npubEncode(_ana);
    final rootId = 'e' * 64;
    relay.events.addAll([
      {
        'id': rootId,
        'pubkey': _marie,
        'created_at': now - 4 * 3600,
        'kind': 1,
        'tags': [
          ['p', FeedbackService.officialHex],
          ['t', 'feedback'],
          ['t', 'rendering-issue'],
        ],
        'content': 'Wide tables are cut off on the right, as nostr:$ana '
            'noticed too. Three examples:\n\n'
            'https://img.example/0.png\nhttps://img.example/1.png\n'
            'https://img.example/2.png',
      },
      {
        'id': 'f' * 64,
        'pubkey': _agent,
        'created_at': now - 3600,
        'kind': 1,
        'tags': [
          ['e', rootId, '', 'root'],
          ['p', _marie],
        ],
        'content': 'Thanks nostr:${NostrService.npubEncode(_marie)}! '
            'Proposal: wide tables scroll sideways.',
      },
    ]);
    final note = FeedbackNote.fromEvent(relay.events[relay.events.length - 2]);
    await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _withEmoji(buildEinkTheme()),
        home: FeedbackThreadScreen(root: note, service: service)));
    await settle(tester);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/feedback_6_chips_images.png'));

    await tester.tap(find.byType(Image).at(1));
    await settle(tester);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/feedback_7_image_viewer.png'));
  }, skip: !_enabled);

  testWidgets('images added to new feedback', (tester) async {
    phone(tester);
    NewFeedbackScreen.debugPickImages =
        () async => [_fakePage(0), _fakePage(1)];
    addTearDown(() => NewFeedbackScreen.debugPickImages = null);
    await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _withEmoji(buildEinkTheme()),
        home: NewFeedbackScreen(service: service)));
    await settle(tester);
    await tester.tap(find.text('Bug'));
    await tester.enterText(find.widgetWithText(TextField, 'Subject'),
        'Wide tables are cut off');
    await tester.enterText(
        find.widgetWithText(
            TextField, 'What happened, or what would you like?'),
        'The last columns never show, even in landscape.');
    await tester.tap(find.text('Add images'));
    await settle(tester);
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await settle(tester);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/feedback_8_new_with_images.png'));
  }, skip: !_enabled);

  testWidgets('replying offline, then sending the same reply again',
      (tester) async {
    phone(tester);
    relay.offline = true;
    addTearDown(() => relay.offline = false);
    await tester.pumpWidget(app());
    await settle(tester);
    await tester.enterText(
        find.byType(TextField), 'Yes please, my feeds have long names too');
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/feedback_9_reply_offline.png'));
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField), 'Yes please, my feeds have long names too');
    await tester.tap(find.byTooltip('Send'));
    await settle(tester);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/feedback_10_reply_repeated.png'));
    await tester.pump(const Duration(seconds: 6));
    await tester.runAsync(() async {
      for (final item in await OutboxService.instance.items()) {
        await OutboxService.instance.delete(item.id!);
      }
    });
  }, skip: !_enabled);

  testWidgets('release notes', (tester) async {
    phone(tester);
    final pages = [for (var i = 0; i < 3; i++) _fakePage(i)];
    noteImageProvider = (url) => MemoryImage(pages[int.parse(
        RegExp(r'(\d)\.png').firstMatch(url)!.group(1)!)]);
    addTearDown(() => noteImageProvider = NetworkImage.new);
    Map<String, dynamic> note(String id, String pubkey, int ago,
            String content) =>
        {
          'id': id,
          'pubkey': pubkey,
          'created_at': now - ago,
          'kind': 1,
          'tags': [
            ['p', FeedbackService.officialHex],
            ['t', 'feedback'],
            ['t', 'einkreader'],
            ['t', 'release-notes'],
            ['subject', content.split('\n').first],
          ],
          'content': content,
        };
    const play = 'Update from Google Play: '
        'https://play.google.com/store/apps/details?id=com.xlcollective.einkreader\n\n'
        'All versions: https://einkreader.app/changelog';
    NostrProfileCache.debugPut(NostrProfile(
        pubkey: FeedbackService.officialHex, name: 'einkReader', about: ''));
    relay.events.addAll([
      // As tool/nostr_release_note.py writes them.
      note('1' * 63 + '0', FeedbackService.officialHex, 2 * 3600,
          "einkReader 0.6.33 on Google Play: what's new\n\n"
          'Read articles leave To Read (0.6.33)\n'
          "- Once you've read an article you saved, it leaves the To Read "
          "tab, so the list only holds what's still waiting for you.\n"
          "- You'll find it in the Read tab, still bookmarked.\n"
          '- If you mark it unread, it goes back to To Read.\n\n'
          '$play\n\n'
          'https://img.example/0.png\nhttps://img.example/1.png'),
      note('2' * 63 + '0', FeedbackService.officialHex, 6 * 86400,
          "einkReader 0.6.32 on Google Play: what's new\n\n"
          'Feedback works offline (0.6.32)\n'
          '- Replies and reactions in a feedback thread now work offline. '
          'They wait in the outbox and go out on the next sync.\n\n'
          '$play\n\nhttps://img.example/2.png'),
      // Anyone can add the hashtag: not counted as release notes.
      note('3' * 63 + '0', _ana, 3600, 'My own release notes!'),
    ]);
    await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _withEmoji(buildEinkTheme()),
        home: FeedbackScreen(service: service)));
    await settle(tester);
    await tester.tap(find.text('Release notes 2'));
    await settle(tester);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/feedback_11_release_notes.png'));

    await tester.tap(find.textContaining('0.6.33 on Google Play').first);
    await settle(tester);
    // Let the pictures decode.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/feedback_12_release_note.png'));
  }, skip: !_enabled);

  testWidgets('tagging new feedback', (tester) async {
    phone(tester);
    await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _withEmoji(buildEinkTheme()),
        home: NewFeedbackScreen(
            service: service, url: 'https://example.org/post')));
    await settle(tester);
    await tester.tap(find.text('Rendering issue'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Subject'),
        'Embedded post shows as loose lines');
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/feedback_5_new_tagged.png'));
  }, skip: !_enabled);

  testWidgets('"new" counts replies only, and clears on opening', (tester) async {
    phone(tester);
    final me = (await service.myPubkey)!;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('feedback_seen_baseline', now - 3600);
    await prefs.remove('feedback_thread_seen');
    final mineId = '9' * 64;
    Map<String, dynamic> event(String id, String pubkey, int ago, int kind,
            String content, List<List<String>> tags) =>
        {
          'id': id,
          'pubkey': pubkey,
          'created_at': now - ago,
          'kind': kind,
          'tags': tags,
          'content': content,
        };
    relay.events.addAll([
      event(mineId, me, 40 * 60, 1, 'Could the list show unread counts?', [
        ['p', FeedbackService.officialHex],
        ['t', 'feedback'],
        ['t', 'feature-request'],
      ]),
      // One new reply…
      event('8' * 64, _marie, 20 * 60, 1, 'Yes, I would like that too.', [
        ['e', mineId, '', 'root'],
        ['p', me],
      ]),
      // …and three new reactions, which don't count as "new".
      for (final (who, ago, emoji) in [
        (_marie, 25 * 60, '👍'),
        (_ana, 15 * 60, '👍'),
        (_ana, 14 * 60, '❤️'),
      ])
        event('$who${ago}r', who, ago, 7, emoji, [
          ['e', mineId],
          ['p', me],
        ]),
    ]);
    await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _withEmoji(buildEinkTheme()),
        home: FeedbackScreen(service: service)));
    // The list shows no spinner while it loads: wait for the notes.
    for (var i = 0; i < 50 && find.text('1 new').evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(find.text('1 new'), findsOneWidget);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/feedback_13_new_replies.png'));
    await tester.tap(find.text('Could the list show unread counts?'));
    await settle(tester);
    Navigator.of(tester.element(find.byType(FeedbackThreadScreen))).pop();
    await settle(tester);
    expect(find.text('1 new'), findsNothing);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/feedback_14_new_cleared.png'));
  }, skip: !_enabled);
}

/// A grey page with a title bar and lines of "text", numbered [i].
Uint8List _fakePage(int i) {
  final page = img.Image(width: 300, height: 400)
    ..clear(img.ColorRgb8(255, 255, 255));
  img.fillRect(page,
      x1: 20, y1: 24, x2: 220, y2: 44, color: img.ColorRgb8(40, 40, 40));
  for (var y = 70; y < 360; y += 22) {
    img.fillRect(page,
        x1: 20,
        y1: y,
        x2: 280 - (y * (i + 3)) % 90,
        y2: y + 8,
        color: img.ColorRgb8(150, 150, 150));
  }
  img.drawRect(page,
      x1: 0, y1: 0, x2: 299, y2: 399, color: img.ColorRgb8(0, 0, 0));
  return img.encodePng(page);
}

ThemeData _withEmoji(ThemeData theme) => theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamilyFallback: ['NotoColorEmoji']));

Future<void> _loadFonts() async {
  final flutterRoot = Platform.environment['FLUTTER_ROOT']!;
  final cache =
      p.join(flutterRoot, 'bin', 'cache', 'artifacts', 'material_fonts');
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      final bytes = await File(path).readAsBytes();
      loader.addFont(
          Future.value(ByteData.sublistView(Uint8List.fromList(bytes))));
    }
    await loader.load();
  }

  await load('Roboto', [
    for (final f in ['Regular', 'Medium', 'Bold', 'Italic'])
      p.join(cache, 'Roboto-$f.ttf'),
  ]);
  await load('MaterialIcons', [p.join(cache, 'MaterialIcons-Regular.otf')]);
  await load(readingFontFamily, [
    for (final f in ['Regular', 'Bold', 'Italic'])
      p.join('test', 'screenshots', 'fonts', 'PTSerif-$f.ttf'),
  ]);
  const emoji = '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf';
  if (File(emoji).existsSync()) await load('NotoColorEmoji', [emoji]);
}
