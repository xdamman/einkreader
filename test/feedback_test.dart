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
import 'package:einkreader/services/profile_service.dart';
import 'package:einkreader/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// An in-memory relay: stores published events and answers NIP-01 filters.
class _FakeRelay extends NostrService {
  final events = <Map<String, dynamic>>[];

  @override
  Future<int> publish(Map<String, dynamic> event,
      {Duration timeout = const Duration(seconds: 8)}) async {
    events.add(event);
    return 1;
  }

  @override
  Future<List<Map<String, dynamic>>> query(Map<String, dynamic> filter,
      {Duration timeout = const Duration(seconds: 8)}) async {
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
    addTearDown(() => NostrProfileScreen.debugLoadNotes = null);
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
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

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
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('React'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Other…'), findsOneWidget);
    await tester.tap(find.text('🔥'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

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

  testWidgets('the new-feedback form: public warning, identity, prefilled '
      'link, screenshot', (tester) async {
    await tester.runAsync(() async {
      await ProfileService.instance.createIdentity();
      ProfileService.instance.debugPublish = (_) async => 1;
      await ProfileService.instance.saveProfile(const Profile(name: 'Xavier'));
    });
    addTearDown(() => ProfileService.instance.debugPublish = null);
    final shot = Uint8List.fromList(
        img.encodePng(img.Image(width: 4, height: 4)));
    NewFeedbackScreen.debugPickImage = () async => shot;
    addTearDown(() => NewFeedbackScreen.debugPickImage = null);
    final feedback = _NoUploadFeedback(relay);
    // Tablet-sized, like the e-ink device: the whole form fits.
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    FeedbackNote? posted;
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => posted = await openNewFeedback(context,
                service: feedback, url: 'https://example.org/article'),
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

    expect(find.textContaining('Feedback is public'), findsOneWidget);
    expect(find.textContaining('personal information'), findsOneWidget);
    expect(find.text('Posting as Xavier'), findsOneWidget);
    expect(find.textContaining('npub1'), findsOneWidget);
    expect(find.text('https://example.org/article'), findsOneWidget,
        reason: 'the link is prefilled');

    await tester.tap(find.text('Attach a screenshot'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Remove'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Subject'), 'Parsing issue');
    await tester.enterText(
        find.widgetWithText(
            TextField, 'What happened, or what would you like?'),
        'Images are missing.');
    await tester.tap(find.text('Post publicly'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(feedback.uploaded, shot);
    final event = relay.events.last;
    expect(event['tags'], anyElement(equals(['subject', 'Parsing issue'])));
    expect(event['tags'],
        anyElement(equals(['r', 'https://example.org/article'])));
    expect(event['content'], contains('https://blossom.example/abc123.jpg'));
    expect(posted, isNotNull, reason: 'the form returns the posted note');
    // Let the "Feedback posted" snackbar time out.
    await tester.pump(const Duration(seconds: 5));
  });
}
