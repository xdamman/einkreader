// The v3 wireframe, end to end:
//   - swipe-right on any unread feed row marks it read (and the row stays)
//   - home pipeline: Read station with the ★ Favorites chip; Shared station
//   - share composer: profile/email/copy-link work; the Twitter row is
//     inert until an account is connected; sharing to the profile records
//     a Share that the Shared tab shows with medium filtering
import 'dart:convert';
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/home_screen.dart';
import 'package:einkreader/screens/profile_screen.dart';
import 'package:einkreader/widgets/share_note_dialog.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/outbox_service.dart';
import 'package:einkreader/services/plugin_service.dart';
import 'package:einkreader/services/profile_service.dart';
import 'package:einkreader/services/sync_service.dart';
import 'package:einkreader/theme.dart';
import 'package:einkreader/widgets/article_feed.dart';
import 'package:einkreader/widgets/shared_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase.instance;
  late Article article;
  late Highlight highlight;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SyncService.instance.autoSyncOnLaunch = false;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    final tmp = Directory.systemTemp.createTempSync('einkreader_pipeline');
    db.debugDatabasePath = p.join(tmp.path, 'test.db');
    ArchiveStore.instance.debugConfigure(basePath: p.join(tmp.path, 'a'));

    final source = await db.insertSource(Source(
        type: SourceType.rss, title: 'Feed', url: 'https://x', createdAt: 0));
    await db.insertArticleIfNew(Article(
      sourceId: source.id!,
      guid: 'a1',
      title: 'Unread Story',
      contentMarkdown: 'the passage lives here',
      publishedAt: 100,
      createdAt: 100,
      fetched: 1,
    ));
    article = (await db.getArticles()).single;
    await db.insertHighlight(Highlight(
        articleId: article.id!,
        text: 'the passage lives here',
        createdAt: 1));
    highlight = (await db.getHighlights()).single;

    // A profile so free sharing fully works.
    await ProfileService.instance.createIdentity();
    ProfileService.instance.debugHttpClient = MockClient(
        (request) async => http.Response(jsonEncode({'ok': true}), 200));
    await ProfileService.instance.registerUsername('xavier');
    ProfileService.instance.debugHttpClient = null;
    ProfileService.instance.debugPublish = (event) async => 1;
    ProfileService.instance.debugFetchHighlightEvents = (_) async => [];
  });

  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  testWidgets('swiping an unread feed row right marks it read in place',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: Scaffold(
        body: ArticleFeed(
          articles: [article],
          emptyMessage: 'empty',
          onChanged: () {},
        ),
      ),
    ));
    await settle(tester);

    expect(article.read, 0);
    await tester.drag(find.text('Unread Story'), const Offset(400, 0));
    await settle(tester);

    final updated = (await tester.runAsync(() => db.getArticle(article.id!)))!;
    expect(updated.read, 1, reason: 'swipe right = mark as read, everywhere');
    // The row is not dismissed — still on screen.
    expect(find.text('Unread Story'), findsOneWidget);
    // Restore unread for later assertions.
    await tester
        .runAsync(() => db.markArticleRead(article.id!, read: false));
  });

  testWidgets('composer: free rows active, Twitter inert until connected',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: Scaffold(
          body: ShareNoteDialog(
              article: article,
              highlights: [highlight],
              shareByDefault: true)),
    ));
    await settle(tester);
    await settle(tester);

    expect(find.text('Your profile'), findsOneWidget);
    expect(find.text('Compose an email…'), findsOneWidget);
    expect(find.text('Copy link to this quote'), findsOneWidget);
    expect(find.text('Tweet it'), findsOneWidget);

    // Without a connected account the Twitter row is inert and says how
    // to enable it — no pitch, no subscription.
    expect(find.text('connect Twitter in Settings'), findsOneWidget);
    await tester.ensureVisible(find.text('Tweet it'));
    await tester.tap(find.text('Tweet it'), warnIfMissed: false);
    await settle(tester);
    expect(find.text('Free forever'), findsNothing);
  });

  testWidgets('sharing to the profile records a Share shown in Shared',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: Scaffold(
          body: ShareNoteDialog(
              article: article,
              highlights: [highlight],
              shareByDefault: true)),
    ));
    await settle(tester);
    await settle(tester);

    // Add a note, keep the default profile check, share.
    await tester.enterText(
        find.widgetWithText(TextField, 'Your note (optional)'), 'my take');
    await tester.ensureVisible(find.text('Share'));
    await tester.tap(find.text('Share'), warnIfMissed: false);
    await settle(tester);
    await settle(tester);

    final shares = await tester.runAsync(() => db.getShares());
    expect(shares, hasLength(1));
    expect(shares!.single.medium, 'profile');
    expect(shares.single.ref, isNotNull, reason: 'event id for the permalink');
    expect(shares.single.highlightComment, 'my take');

    // The Shared column renders it with filter chips.
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: Scaffold(
          body: SharedList(shares: shares, onChanged: () {})),
    ));
    await settle(tester);
    expect(find.text('the passage lives here'), findsOneWidget);
    expect(find.text('my take'), findsOneWidget);
    expect(find.text('⌂ profile'), findsNWidgets(2)); // filter chip + tag
    // Filtering by a medium keeps the entry visible.
    await tester.tap(find.text('⌂ profile').first);
    await settle(tester);
    expect(find.text('the passage lives here'), findsOneWidget);
  });

  test('quoteLink points at the username quote permalink', () async {
    final link = await ProfileService.instance.quoteLink('a' * 64);
    expect(link,
        'https://einkreader.app/xavier/q/${'a' * 12}');
  });

  testWidgets('immediate actions live below the Share button', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: Scaffold(
          body: ShareNoteDialog(
              article: article,
              highlights: [highlight],
              shareByDefault: true)),
    ));
    await settle(tester);
    await settle(tester);
    final shareY = tester.getTopLeft(find.text('Share')).dy;
    expect(tester.getTopLeft(find.text('Copy link to this quote')).dy,
        greaterThan(shareY),
        reason: 'copy link is a hand-off, not a channel');
    expect(tester.getTopLeft(find.text('Compose an email…')).dy,
        greaterThan(shareY));
    // And neither carries a checkbox.
    expect(
        find.ancestor(
            of: find.text('Compose an email…'),
            matching: find.byIcon(Icons.check_box_outline_blank)),
        findsNothing);
  });

  test('a queued email share is delivered by the outbox flush', () async {
    await OutboxService.instance.enqueueEmailShare(
      to: 'marc@example.com',
      subject: 'A quote',
      text: 'the passage lives here',
      description: 'Email to Marc: A quote',
      error: 'offline',
    );
    var sentTo = '';
    OutboxService.instance.debugEmailSend =
        ({required to, required subject, required text}) async {
      sentTo = to;
    };
    await OutboxService.instance.flush();
    expect(sentTo, 'marc@example.com');
    expect((await db.outboxItems()).where((i) => i.kind == 'email'), isEmpty);
    OutboxService.instance.debugEmailSend = null;
  });

  testWidgets('sharing several highlights combined publishes each',
      (tester) async {
    final second = await tester.runAsync(() async {
      await db.insertHighlight(Highlight(
          articleId: article.id!,
          text: 'a second passage',
          createdAt: 2));
      return (await db.getHighlights())
          .firstWhere((h) => h.text == 'a second passage');
    });
    final before =
        (await tester.runAsync(() => db.getShares()))!.length;

    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: Scaffold(
          body: ShareNoteDialog(
              key: const ValueKey('multi'),
              article: article,
              highlights: [highlight, second!],
              shareByDefault: true)),
    ));
    await settle(tester);
    await settle(tester);

    // Both quotes in the preview, no per-quote note field.
    expect(find.textContaining('2 highlights ·'), findsOneWidget);
    expect(find.text('Your note (optional)'), findsNothing);

    await tester.ensureVisible(find.text('Share'));
    await tester.tap(find.text('Share'), warnIfMissed: false);
    await settle(tester);
    await settle(tester);

    final shares = await tester.runAsync(() => db.getShares());
    // One profile share per not-yet-published highlight (the first was
    // already on the profile from the earlier test).
    expect(shares!.length, before + 1);
    expect(shares.where((sh) => sh.medium == 'profile'), isNotEmpty);
    // Keep the later profile-screen test deterministic: a comment-less
    // shared quote would show its "add a comment" nudge there.
    await tester.runAsync(
        () => db.updateHighlightComment(second.id!, 'second take'));
  });

  testWidgets('profile screen lists shared highlights, grouped by story',
      (tester) async {
    // The earlier test shared the highlight to the profile; the viewer
    // must show it from the local record (even if publishing is queued).
    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(), home: const ProfileScreen()));
    await settle(tester);
    await settle(tester);
    expect(find.textContaining('Shared highlights ·'), findsOneWidget);
    expect(find.text('Unread Story'), findsOneWidget); // the story group
    expect(find.text('the passage lives here'), findsOneWidget);
    expect(find.text('my take'), findsOneWidget); // the comment
    // With a comment present there is no nudge…
    expect(find.text('Add a comment about this quote'), findsNothing);

    // …and a comment-less shared quote gets one (author-only view).
    await tester.runAsync(() async {
      await db.updateHighlightComment(highlight.id!, null);
    });
    // A distinct key forces a fresh screen State (same widget type would
    // reuse the old one and keep the stale shares).
    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(),
        home: const ProfileScreen(key: ValueKey('recheck'))));
    await settle(tester);
    await settle(tester);
    await tester.ensureVisible(find.text('Add a comment about this quote'));
    expect(find.text('Add a comment about this quote'), findsOneWidget);
    await tester.tap(find.text('Add a comment about this quote'),
        warnIfMissed: false);
    await settle(tester);
    await settle(tester);
    expect(find.text('Your note (optional)'), findsOneWidget,
        reason: 'the nudge opens the note/share dialog');
    // Restore the comment for any later assertions.
    await tester.runAsync(
        () => db.updateHighlightComment(highlight.id!, 'my take'));
  });

  testWidgets('opening the app never flashes the add-a-source screen',
      (tester) async {
    // Sources exist in the db; before the first load lands the feed must
    // render blank, not the empty-state call-to-action.
    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(), home: const HomeScreen()));
    await tester.pump(); // first frame, load still in flight
    expect(find.textContaining('No sources yet'), findsNothing);
    await settle(tester);
    await settle(tester);
    expect(find.text('Unread Story'), findsOneWidget,
        reason: 'the feed appears directly');
  });

  test('offline profile update waits in the outbox', () async {
    ProfileService.instance.debugPublish =
        (event) async => throw Exception('offline');
    await ProfileService.instance
        .saveProfile(const Profile(name: 'Xavier', about: 'offline edit'));
    final queued = await db.outboxItems();
    expect(
        queued.where(
            (i) => i.kind == 'nostr' && i.text.contains('Profile update')),
        isNotEmpty,
        reason: 'editing the profile offline queues the kind-0 event');
    ProfileService.instance.debugPublish = (event) async => 1;
  });

  test('each plugin is gated by its own toggle', () async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in ['plugin_twitter_on', 'plugin_email_on']) {
      await prefs.remove(key);
    }
    await PluginService.instance.setEmailOn(true);
    expect(await PluginService.instance.emailActive, isTrue);
    expect(await PluginService.instance.twitterActive, isFalse,
        reason: 'each plugin still needs its own toggle');
  });
}
