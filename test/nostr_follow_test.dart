// Following a Nostr profile from the Add source screen: npub / NIP-05 /
// name-search input, per-kind toggles (notes, long reads, bookmarks — all on
// by default), and long-form articles stored as ready Markdown.
import 'dart:convert';
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/add_source_screen.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/nostr_service.dart';
import 'package:einkreader/services/sync_service.dart';
import 'package:einkreader/services/twitter_service.dart';
import 'package:einkreader/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Serves canned long reads / notes without any relay.
class _FakeNostr extends NostrService {
  @override
  Future<List<NostrLongRead>> fetchLongReads(String npub) async => [
        NostrLongRead(
          id: 'lr1',
          title: 'On Reading Slowly',
          summary: 'An essay',
          contentMarkdown: '# On Reading Slowly\n\nParagraph one.',
          publishedAt: DateTime.fromMillisecondsSinceEpoch(1000000),
        ),
      ];

  @override
  Future<List<NostrItem>> fetchAuthorNotes(String npub) async => const [
        NostrItem(id: 'n1', content: 'a short note about reading'),
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase.instance;
  late Directory tmp;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    tmp = Directory.systemTemp.createTempSync('einkreader_follow');
    db.debugDatabasePath = p.join(tmp.path, 'test.db');
    ArchiveStore.instance.debugConfigure(basePath: p.join(tmp.path, 'a'));
  });

  test('resolveNip05 reads the domain well-known file', () async {
    final nostr = NostrService(
      client: MockClient((request) async {
        expect(request.url.toString(),
            'https://cash.app/.well-known/nostr.json?name=jack');
        return http.Response(
            jsonEncode({
              'names': {'jack': 'a' * 64}
            }),
            200);
      }),
    );
    expect(await nostr.resolveNip05('Jack@cash.app'), 'a' * 64);
  });

  test('resolveNip05 rejects unknown names', () async {
    final nostr = NostrService(
      client: MockClient(
          (request) async => http.Response(jsonEncode({'names': {}}), 200)),
    );
    expect(nostr.resolveNip05('ghost@example.com'), throwsException);
  });

  test('npubEncode round-trips', () {
    final hex = List.generate(32, (i) => i)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    expect(NostrService.decodeNpub(NostrService.npubEncode(hex)), hex);
  });

  test('long reads sync as complete Markdown articles', () async {
    final sync = SyncService.forTest(
      http: MockClient((request) async => http.Response('nope', 400)),
      twitter: TwitterService(
          accessToken: () async => 't',
          client: MockClient((request) async => http.Response('{}', 200))),
    )..nostr = _FakeNostr();

    final npub = NostrService.npubEncode('b' * 64);
    final source = await db.insertSource(Source(
        type: SourceType.nostrLongReads,
        title: 'Author · Long reads',
        url: npub,
        createdAt: 0));
    await sync.syncSources([source]);

    final articles = await db.getArticles(sourceId: source.id);
    expect(articles, hasLength(1));
    expect(articles.single.title, 'On Reading Slowly');
    expect(articles.single.fetched, 1,
        reason: 'kind 30023 content is already Markdown — no download');
    expect(articles.single.contentMarkdown, contains('Paragraph one.'));
  });

  testWidgets('follow section: input plus three toggles, all on',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: const AddSourceScreen(),
    ));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Follow'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Follow a Nostr profile'), findsOneWidget);
    expect(find.text('npub, name@domain, or name'), findsOneWidget);
    for (final toggle in ['Notes', 'Long reads', 'Bookmarks']) {
      final tile = tester.widget<SwitchListTile>(find.ancestor(
          of: find.text(toggle), matching: find.byType(SwitchListTile)));
      expect(tile.value, isTrue, reason: '$toggle defaults to on');
    }
  });
}
