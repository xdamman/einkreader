// Feedback threads: who reacted (long press on a reaction) and @mentions
// while replying. Run:
//
//   flutter test test/screenshots/feedback_shot_test.dart \
//     --update-goldens --dart-define=screenshots=true
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/screens/feedback_screen.dart';
import 'package:einkreader/screens/nostr_profile_screen.dart';
import 'package:einkreader/services/feedback_service.dart';
import 'package:einkreader/services/nostr_service.dart';
import 'package:einkreader/services/profile_service.dart';
import 'package:einkreader/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _enabled = bool.fromEnvironment('screenshots');

const _marie =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _agent =
    '735beae7899fa8c1ebe0e81087aeae773d37fba3f189f2c2e7808c7e1387b58f';
const _ana = '3333333333333333333333333333333333333333333333333333333333333333';

/// Answers from what it was given; publishing always succeeds.
class _Relay extends NostrService {
  final events = <Map<String, dynamic>>[];

  @override
  Future<int> publish(Map<String, dynamic> event,
      {Duration timeout = const Duration(seconds: 8)}) async {
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
    await tester.enterText(find.byType(TextField), 'Looks good, @xa');
    await tester.pump();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/feedback_2_mention_suggestions.png'));
    await tester.tap(find.text("Xavier's agent").last);
    await tester.pump();
    await tester.enterText(find.byType(TextField),
        "Looks good, @Xavier's agent can it also reset to the feed's name?");
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
