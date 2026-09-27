// The Inbox category: always in the feed strip (even empty), explaining how
// to fill it — the name@einkreader.app address, or a prompt to create a
// profile — listing emails from new senders to accept, and a second row of
// senders ordered by how much each sent.
import 'dart:convert';
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/home_screen.dart';
import 'package:einkreader/screens/sources_screen.dart';
import 'package:einkreader/services/profile_service.dart';
import 'package:einkreader/services/sync_service.dart';
import 'package:einkreader/theme.dart';
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ProfileService.instance.debugResetActiveCache();
    SyncService.instance.autoSyncOnLaunch = false;
    SyncService.instance.emailRequests = [];
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_inbox_ui').path,
        'test.db');
    await db.insertSource(Source(
        type: SourceType.rss,
        title: 'Alpha',
        url: 'https://alpha.example',
        createdAt: 0));
  });

  tearDown(() async {
    await db.debugReset();
    SyncService.instance.emailRequests = [];
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 2; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }
  }

  Future<void> openInbox(WidgetTester tester, Key key) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        MaterialApp(theme: buildEinkTheme(), home: HomeScreen(key: key)));
    await settle(tester);
    await tester.tap(find.text('Inbox').first);
    await settle(tester);
  }

  testWidgets('without a profile, the empty Inbox offers to create one',
      (tester) async {
    await openInbox(tester, const ValueKey('no-profile'));
    expect(
        find.textContaining('Set up your profile to create an email '
            'address'),
        findsOneWidget);
    expect(find.text('Create an einkreader profile'), findsOneWidget);
    expect(find.text('Nothing in your Inbox yet.'), findsOneWidget);
  });

  testWidgets('with a profile: address, requests, senders by count',
      (tester) async {
    await tester.runAsync(() async {
      await ProfileService.instance.createIdentity();
      ProfileService.instance.debugHttpClient = MockClient(
          (request) async => http.Response(jsonEncode({'ok': true}), 200));
      await ProfileService.instance.registerUsername('xavier');
      ProfileService.instance.debugHttpClient = null;
      final inbox = await db.ensureEmailSource();
      Future<void> add(String from, int n) async {
        for (var i = 0; i < n; i++) {
          await db.insertArticleIfNew(Article(
            sourceId: inbox.id!,
            guid: '$from-$i',
            title: 'From $from #$i',
            author: from,
            contentMarkdown: 'Body',
            publishedAt: 100 + i,
            createdAt: 100,
            fetched: 1,
          ));
        }
      }

      await add('amy@example.com', 1);
      await add('zed@example.com', 3);
    });
    SyncService.instance.emailRequests = [
      const EmailRequest(
        id: 'inbox/pk/request-1.json',
        from: 'stranger@example.net',
        item: {
          'subject': 'To read',
          'url': 'https://news.example/story',
        },
      ),
    ];

    await openInbox(tester, const ValueKey('with-profile'));
    expect(find.text('xavier@einkreader.app'), findsOneWidget);
    expect(find.textContaining('Send any link you want to read later'),
        findsOneWidget);
    expect(find.textContaining('stranger@example.net', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('wants to send you', findRichText: true),
        findsOneWidget);
    expect(find.text('Accept sender'), findsOneWidget);

    // The sender row: most items first, even against alphabetical order.
    final zedX = tester.getTopLeft(find.text('zed@example.com').first).dx;
    final amyX = tester.getTopLeft(find.text('amy@example.com').first).dx;
    expect(zedX, lessThan(amyX));

    await tester.tap(find.text('amy@example.com').first);
    await settle(tester);
    expect(find.text('From amy@example.com #0'), findsOneWidget);
    expect(find.text('From zed@example.com #0'), findsNothing);
  });

  testWidgets('Inbox is the first chip after All', (tester) async {
    await tester.runAsync(() => db.insertSource(Source(
        type: SourceType.rss,
        title: 'Aardvark Weekly',
        url: 'https://aardvark.example',
        createdAt: 0)));
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      // Articles so the RSS chips show up.
      for (final s in await db.getSources()) {
        await db.insertArticleIfNew(Article(
            sourceId: s.id!, guid: 'g${s.id}', title: 'Story ${s.title}',
            contentMarkdown: 'x', publishedAt: 1, createdAt: 1, fetched: 1));
      }
    });
    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(), home: const HomeScreen(key: ValueKey('o'))));
    await settle(tester);
    final all = tester.getTopLeft(find.text('All').first).dx;
    final inbox = tester.getTopLeft(find.text('Inbox').first).dx;
    final aardvark = tester.getTopLeft(find.text('Aardvark Weekly').first).dx;
    expect(all, lessThan(inbox));
    expect(inbox, lessThan(aardvark),
        reason: 'Inbox leads even against alphabetical order');
  });

  testWidgets('no sources: the sync icon is hidden', (tester) async {
    // A fresh, empty database: no source at all.
    await tester.runAsync(() async {
      await db.debugReset();
      db.debugDatabasePath = p.join(
          Directory.systemTemp.createTempSync('einkreader_nosrc').path,
          'test.db');
    });
    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(), home: const HomeScreen(key: ValueKey('n'))));
    await settle(tester);
    expect(find.byTooltip('Update all sources'), findsNothing);
  });

  testWidgets('with a source, the sync icon shows', (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(), home: const HomeScreen(key: ValueKey('s'))));
    await settle(tester);
    expect(find.byTooltip('Update all sources'), findsOneWidget);
  });

  testWidgets('sources list: Inbox on top, a trash icon, no unread box',
      (tester) async {
    await tester.runAsync(() => db.ensureEmailSource());
    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(), home: const SourcesScreen()));
    await settle(tester);
    final inboxY = tester.getTopLeft(find.text('Inbox')).dy;
    final alphaY = tester.getTopLeft(find.text('Alpha')).dy;
    expect(inboxY, lessThan(alphaY));
    expect(find.byTooltip('Remove Alpha'), findsOneWidget);
    expect(find.byTooltip('Remove Inbox'), findsNothing,
        reason: 'the built-in Inbox cannot be removed');
    expect(find.byIcon(Icons.more_vert), findsNothing,
        reason: 'no folders: nothing to move to, so no menu');
  });
}
