// In-app feedback on Nostr: notes addressed to the official account, threads
// of replies (NIP-10), emoji reactions (NIP-25) with the reader's favorite
// emojis first, and native profiles opened from any avatar or name.
import 'dart:io';
import 'dart:typed_data';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/screens/feedback_screen.dart';
import 'package:einkreader/screens/nostr_profile_screen.dart';
import 'package:einkreader/services/feedback_service.dart';
import 'package:einkreader/services/nostr_service.dart';
import 'package:einkreader/services/outbox_service.dart';
import 'package:einkreader/services/profile_service.dart';
import 'package:einkreader/theme.dart';
import 'package:einkreader/widgets/markdown_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// An in-memory relay: stores published events and answers NIP-01 filters.
class _FakeRelay extends NostrService {
  final events = <Map<String, dynamic>>[];
  final filters = <Map<String, dynamic>>[];

  /// Queries that come back empty first (a cold, slow relay).
  int emptyAnswers = 0;

  @override
  Future<int> publish(Map<String, dynamic> event,
      {Duration timeout = const Duration(seconds: 8)}) async {
    events.add(event);
    return 1;
  }

  @override
  Future<List<Map<String, dynamic>>> query(Map<String, dynamic> filter,
      {Duration timeout = const Duration(seconds: 8)}) async {
    filters.add(filter);
    if (emptyAnswers > 0) {
      emptyAnswers--;
      return [];
    }
    bool tagged(Map<String, dynamic> e, String name, List values) =>
        (e['tags'] as List).any((t) =>
            (t as List).length >= 2 && t[0] == name && values.contains(t[1]));
    return events.where((e) {
      if (filter['ids'] != null && !(filter['ids'] as List).contains(e['id'])) {
        return false;
      }
      if (filter['kinds'] != null &&
          !(filter['kinds'] as List).contains(e['kind'])) {
        return false;
      }
      if (filter['authors'] != null &&
          !(filter['authors'] as List).contains(e['pubkey'])) {
        return false;
      }
      if (filter['#p'] != null && !tagged(e, 'p', filter['#p'] as List)) {
        return false;
      }
      if (filter['#e'] != null && !tagged(e, 'e', filter['#e'] as List)) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  Future<Map<String, NostrProfile>> fetchProfiles(
          Iterable<String> hexPubkeys) async =>
      {};
}

/// No relay reachable: every publish is refused.
class _OfflineRelay extends _FakeRelay {
  @override
  Future<int> publish(Map<String, dynamic> event,
          {Duration timeout = const Duration(seconds: 8)}) async =>
      0;
}

/// Uploads nowhere: returns a fixed URL for the screenshot.
class _NoUploadFeedback extends FeedbackService {
  _NoUploadFeedback(NostrService nostr) : super(nostr: nostr);
  Uint8List? uploaded;

  @override
  Future<String> uploadScreenshot(Uint8List bytes) async {
    uploaded = bytes;
    return 'https://blossom.example/abc123.jpg';
  }
}

/// Gives the database real time until loading (the app-bar spinner) ends,
/// then lets animations settle.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase.instance;
  late _FakeRelay relay;
  late FeedbackService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_feedback').path,
        'test.db');
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ProfileService.instance.debugResetActiveCache();
    NostrProfileCache.debugClear();
    await db.clearNostrCache();
    relay = _FakeRelay();
    service = FeedbackService(nostr: relay);
  });

  test('the official account is the npub the app was given', () {
    expect(FeedbackService.officialNpub,
        'npub1dq33rr42kfeqss8kjpd0l4tn20ppq9fgu5j28c08vlsqjazr8t5qltl4h7');
    expect(NostrService.npubEncode(FeedbackService.officialHex),
        FeedbackService.officialNpub);
  });

  test('post, reply, react: threads and reactions come back together',
      () async {
    await ProfileService.instance.createIdentity();
    final me = (await service.myPubkey)!;

    final note = await service.post('Dark mode for night reading?');
    final event = relay.events.single;
    expect(event['tags'], anyElement(equals(['p', FeedbackService.officialHex])));
    expect(event['tags'], anyElement(equals(['client', 'einkreader'])));

    final reply = await service.reply(note, 'Yes please!');
    final nested = await service.reply(reply, 'Agreed with you');
    expect(relay.events.last['tags'],
        anyElement(equals(['e', note.id, '', 'root'])));
    expect(relay.events.last['tags'],
        anyElement(equals(['e', reply.id, '', 'reply'])));

    await service.react(note, '🎉');
    await service.react(reply, '👍');

    final list = await service.feedback();
    expect(list.notes.map((n) => n.id), [note.id],
        reason: 'replies are not listed as top-level feedback');
    expect(list.replyCounts[note.id], 2);
    expect(list.notes.single.reactions['🎉'], {me});

    final thread = await service.thread(note.id);
    expect(thread.map((n) => n.id), [note.id, reply.id, nested.id]);
    expect(thread[2].replyToId, reply.id);
    expect(thread[1].reactions['👍'], {me});
  });

  test('quick emojis: defaults first, then the reader\'s most used',
      () async {
    expect(await FeedbackService.quickEmojis(), FeedbackService.defaultEmojis);
    await ProfileService.instance.createIdentity();
    final note = await service.post('hi');
    await service.react(note, '🎉');
    await service.react(note, '🎉');
    await service.react(note, '🤔');
    final quick = await FeedbackService.quickEmojis();
    expect(quick.take(2), ['🎉', '🤔']);
    expect(quick, hasLength(6));
  });

  testWidgets('the list shows authors; avatar and name open their profile',
      (tester) async {
    const author =
        '1111111111111111111111111111111111111111111111111111111111111111';
    NostrProfileCache.debugPut(const NostrProfile(
        pubkey: author, name: 'Ada', about: 'Reads on paper.'));
    NostrProfileScreen.debugLoadNotes = (_) async =>
        const [NostrItem(id: 'x', content: 'an older note by Ada')];
    NostrProfileScreen.debugLoadActivity = (_) async => const [];
    addTearDown(() {
      NostrProfileScreen.debugLoadNotes = null;
      NostrProfileScreen.debugLoadActivity = null;
    });
    relay.events.add({
      'id': 'f1',
      'pubkey': author,
      'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600,
      'kind': 1,
      'tags': [
        ['p', FeedbackService.officialHex]
      ],
      'content': 'Highlights export to Obsidian would be great',
    });

    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(), home: FeedbackScreen(service: service)));
    await settle(tester);

    expect(find.textContaining('Obsidian', findRichText: true), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('New feedback'), findsOneWidget);

    await tester.tap(find.text('Ada'));
    // Build the route first, then give its database read real time.
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.byType(NostrProfileScreen), findsOneWidget);
    expect(find.text('Reads on paper.'), findsOneWidget);
    expect(find.textContaining('an older note', findRichText: true),
        findsOneWidget);
    expect(find.text('Follow'), findsOneWidget);
  });

  testWidgets('reacting picks from the quick emojis and shows the count',
      (tester) async {
    await tester.runAsync(() => ProfileService.instance.createIdentity());
    final note =
        (await tester.runAsync(() => service.post('Love the reader')))!;
    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(), home: FeedbackScreen(service: service)));
    await settle(tester);

    await tester.tap(find.byTooltip('React'));
    await settle(tester);
    expect(find.text('Other…'), findsOneWidget);
    await tester.tap(find.text('🔥'));
    await settle(tester);

    expect(find.text('🔥 1'), findsOneWidget);
    final reaction = relay.events.last;
    expect(reaction['kind'], 7);
    expect(reaction['content'], '🔥');
    expect(reaction['tags'], anyElement(equals(['e', note.id])));
  });

  test('subject, link and screenshot travel as tags and in the text',
      () async {
    await ProfileService.instance.createIdentity();
    await service.post('The table rendered as raw HTML.',
        subject: 'Broken table',
        url: 'https://example.org/post',
        imageUrl: 'https://blossom.example/shot.jpg');
    final event = relay.events.single;
    expect(event['tags'], anyElement(equals(['subject', 'Broken table'])));
    expect(event['tags'], anyElement(equals(['r', 'https://example.org/post'])));
    expect(event['tags'],
        anyElement(equals(['imeta', 'url https://blossom.example/shot.jpg',
          'm image/jpeg'])));
    // Other clients show the subject and image from the text itself.
    expect(event['content'], startsWith('Broken table\n\n'));
    expect(event['content'], contains('https://blossom.example/shot.jpg'));

    final note = FeedbackNote.fromEvent(event);
    expect(note.subject, 'Broken table');
    expect(note.images, ['https://blossom.example/shot.jpg']);
    expect(note.displayText,
        'The table rendered as raw HTML.\n\nhttps://example.org/post');
  });

  testWidgets('the new-feedback form: public note, identity with switch, '
      'prefilled link with a clear cross, screenshot offered (not included) '
      'post button below', (tester) async {
    await tester.runAsync(() async {
      await ProfileService.instance.createIdentity();
      ProfileService.instance.debugPublish = (_) async => 1;
      await ProfileService.instance.saveProfile(const Profile(name: 'Xavier'));
    });
    addTearDown(() => ProfileService.instance.debugPublish = null);
    var switched = 0;
    NewFeedbackScreen.debugSwitchProfile = (_) async => switched++;
    addTearDown(() => NewFeedbackScreen.debugSwitchProfile = null);
    final shot = Uint8List.fromList(
        img.encodePng(img.Image(width: 4, height: 4)));
    final feedback = _NoUploadFeedback(relay);
    // Tablet-sized, like the e-ink device: the whole form fits.
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    SentFeedback? posted;
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => posted = await openNewFeedback(context,
                service: feedback,
                url: 'https://example.org/article',
                screenshot: shot),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.textContaining('Feedback is public so we can improve'),
        findsOneWidget);
    expect(find.textContaining('personal information'), findsOneWidget);
    expect(find.text('Posting as Xavier'), findsOneWidget);
    expect(find.textContaining('npub1'), findsNothing,
        reason: 'the key is noise for most people');
    expect(find.textContaining('home screen'), findsNothing);
    expect(find.text('https://example.org/article'), findsOneWidget,
        reason: 'the link is prefilled');
    expect(find.text('Remove screenshot'), findsNothing,
        reason: 'no screenshot unless asked for');
    expect(find.text('Include a screenshot of the page'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Subject'), 'Parsing issue');
    await tester.enterText(
        find.widgetWithText(
            TextField, 'What happened, or what would you like?'),
        'Images are missing.');

    // Switching profile keeps what was written.
    await tester.tap(find.text('switch profile'));
    await settle(tester);
    expect(switched, 1);
    expect(find.text('Parsing issue'), findsOneWidget);
    expect(find.text('Images are missing.'), findsOneWidget);

    // One tap attaches the (already captured) screenshot instantly.
    await tester.tap(find.text('Include a screenshot of the page'));
    await tester.pump();
    expect(find.text('Remove screenshot'), findsOneWidget);
    // Tapping the preview opens it almost full screen; tap closes it.
    await tester.tap(find.byType(Image).last);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('Close image'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);

    // The cross clears the link in one tap.
    await tester.tap(find.byTooltip('Remove the link'));
    await tester.pump();
    expect(find.text('https://example.org/article'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'Link (optional)'),
        'https://example.org/other');
    await tester.pump();

    // No action in the app bar: the post button sits below the form.
    expect(
        find.descendant(
            of: find.byType(AppBar), matching: find.byType(TextButton)),
        findsNothing);
    await tester.tap(find.text('Post feedback'));
    await settle(tester);
    expect(posted, isNotNull, reason: 'the form closes with the feedback');
    expect(find.text('Post feedback'), findsNothing);
    await tester.runAsync(() => posted!.sent);

    expect(feedback.uploaded, shot);
    final event = relay.events.last;
    expect(event['tags'], anyElement(equals(['subject', 'Parsing issue'])));
    expect(event['tags'],
        anyElement(equals(['r', 'https://example.org/other'])));
    expect(event['content'], contains('https://blossom.example/abc123.jpg'));
    // Let the "Feedback posted" snackbar time out.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('without asking for it, no screenshot is uploaded',
      (tester) async {
    await tester.runAsync(() async {
      await ProfileService.instance.createIdentity();
      ProfileService.instance.debugPublish = (_) async => 1;
    });
    addTearDown(() => ProfileService.instance.debugPublish = null);
    final feedback = _NoUploadFeedback(relay);
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: NewFeedbackScreen(
          service: feedback,
          screenshot: Uint8List.fromList(
              img.encodePng(img.Image(width: 4, height: 4)))),
    ));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.enterText(
        find.widgetWithText(TextField, 'Subject'), 'No picture');
    await tester.tap(find.text('Post feedback'));
    await settle(tester);
    expect(feedback.uploaded, isNull);
    expect(relay.events.last['content'], isNot(contains('blossom')));
    await tester.pump(const Duration(seconds: 5));
  });

  test('new feedback is shown at once and queued in the outbox when offline',
      () async {
    await ProfileService.instance.createIdentity();
    final offline = FeedbackService(nostr: _OfflineRelay());
    final posting =
        await offline.submit('Posting should be instant', subject: 'Speed');
    expect(posting.draft.sending, isTrue);
    expect(posting.draft.subject, 'Speed');
    expect(posting.draft.pubkey, await offline.myPubkey);

    final sent = await posting.sent;
    expect(sent.queued, isTrue);
    expect(sent.note.sending, isFalse);
    final queued = await OutboxService.instance.items();
    expect(queued, hasLength(1));
    expect(queued.single.kind, 'nostr');
    expect(queued.single.payload, contains(sent.note.id));
    await OutboxService.instance.delete(queued.single.id!);
  });

  testWidgets('the list keeps each feedback to a few lines', (tester) async {
    relay.events.add({
      'id': 'long',
      'pubkey':
          '2222222222222222222222222222222222222222222222222222222222222222',
      'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'kind': 1,
      'tags': [
        ['p', FeedbackService.officialHex]
      ],
      'content': List.filled(40, '**Long** feedback line.').join('\n'),
    });
    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(), home: FeedbackScreen(service: service)));
    await settle(tester);
    final preview = tester.widget<Text>(
        find.textContaining('Long feedback line.'));
    expect(preview.maxLines, 3);
    expect(preview.data, isNot(contains('**')));
    expect(find.byType(MarkdownView), findsNothing,
        reason: 'the full text shows in the thread');
  });

  test('list previews are plain text', () {
    expect(plainPreview('# Title\n\nSee [this](https://x.org) **now**'),
        'Title See this now');
  });

  testWidgets('a profile shows their shared highlights and feedback',
      (tester) async {
    const author =
        '3333333333333333333333333333333333333333333333333333333333333333';
    NostrProfileCache.debugPut(const NostrProfile(
        pubkey: author, name: 'Grace', nip05: 'grace_h@einkreader.app'));
    NostrProfileScreen.debugLoadNotes = (_) async =>
        const [NostrItem(id: 'fb', content: 'Bigger margins please')];
    NostrProfileScreen.debugLoadActivity = (_) async => [
          {
            'id': 'hl',
            'pubkey': author,
            'created_at': 1700000000,
            'kind': 9802,
            'tags': [
              ['title', 'On Reading'],
              ['comment', 'So true'],
            ],
            'content': 'Reading is thinking with a borrowed mind.',
          },
          {
            'id': 'fb',
            'pubkey': author,
            'created_at': 1700000100,
            'kind': 1,
            'tags': [
              ['p', FeedbackService.officialHex],
              ['subject', 'Margins'],
            ],
            'content': 'Margins\n\nBigger margins please',
          },
        ];
    addTearDown(() {
      NostrProfileScreen.debugLoadNotes = null;
      NostrProfileScreen.debugLoadActivity = null;
    });
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(),
        home: const NostrProfileScreen(pubkey: author)));
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('SHARED HIGHLIGHTS · 1'), findsOneWidget);
    expect(find.text('Reading is thinking with a borrowed mind.'),
        findsOneWidget);
    expect(find.text('So true'), findsOneWidget);
    expect(find.text('FEEDBACK · 1'), findsOneWidget);
    expect(find.text('Margins'), findsOneWidget);
    expect(find.text('No recent notes.'), findsOneWidget,
        reason: 'feedback is not repeated among the notes');
    expect(find.text('Public page'), findsOneWidget);
  });

  test('horizontal rules at the edges of an article are dropped', () {
    expect(
        MarkdownView.trimEdgeRules('* * *\n\nHello\n\n---\n\nWorld\n\n* * *\n'),
        'Hello\n\n---\n\nWorld');
    expect(MarkdownView.trimEdgeRules('Just text'), 'Just text');
  });

  test('feedback is cached: instant from disk, then only newer events',
      () async {
    await ProfileService.instance.createIdentity();
    final note = await service.post('Cache me');
    relay.filters.clear();

    // From the local copy alone — no relay query at all.
    final cached = await FeedbackService(nostr: relay).cachedFeedback();
    expect(cached.notes.map((n) => n.id), [note.id]);
    expect(relay.filters, isEmpty);

    // The first refresh is a full sync; later ones ask only for what's
    // newer than the last sync.
    await service.feedback();
    relay.filters.clear();
    await service.feedback();
    expect(relay.filters, isNotEmpty);
    expect(relay.filters.every((f) => f['since'] != null), isTrue,
        reason: 'incremental: every query is bounded by the cache');
  });

  test("posting before the first load doesn't hide older feedback",
      () async {
    // Someone else's feedback from yesterday, on the relays.
    relay.events.add({
      'id': 'older',
      'pubkey': '3333333333333333333333333333333333333333333333333333333333333333',
      'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 86400,
      'kind': 1,
      'tags': [
        ['p', FeedbackService.officialHex]
      ],
      'content': 'Older feedback by someone else',
    });
    await ProfileService.instance.createIdentity();
    // Our own post lands in the cache first (newest event stored)…
    await service.post('My fresh feedback');
    // …yet the first list load still fetches everything.
    final list = await service.feedback();
    expect(list.notes.map((n) => n.id), contains('older'));
  });

  testWidgets('the list loads by itself, even when relays answer late',
      (tester) async {
    relay.events.add({
      'id': 'late',
      'pubkey': '4444444444444444444444444444444444444444444444444444444444444444',
      'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60,
      'kind': 1,
      'tags': [
        ['p', FeedbackService.officialHex]
      ],
      'content': 'Arrived on the second try',
    });
    relay.emptyAnswers = 1; // the first query comes back empty
    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(), home: FeedbackScreen(service: service)));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(seconds: 1));
    }
    await settle(tester);
    expect(find.textContaining('Arrived on the second try', findRichText: true),
        findsOneWidget,
        reason: 'retried automatically — no reload tap needed');
    expect(find.text('No feedback yet — be the first.'), findsNothing);
  });
}
