// Per-profile storage: sources (and everything hanging off them) are
// namespaced to the active profile; a new profile can import feeds and
// highlights from the previous one, per-source; published highlights carry
// the NIP-89 client tag.
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/services/profile_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase.instance;
  late int rssId;
  late int twitterId;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    ProfileService.instance.debugPublish = (event) async => 1;
    ProfileService.instance.debugResetActiveCache();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await db.debugReset();
    db.activeProfile = 'default';
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_pstorage').path,
        'test.db');

    // The default profile's library: two feeds, articles, one highlight.
    final rss = await db.insertSource(Source(
        type: SourceType.rss, title: 'BX1', url: 'https://bx1', createdAt: 0));
    final tw = await db.insertSource(Source(
        type: SourceType.twitterBookmarks,
        title: 'Twitter Bookmarks',
        url: 'xdamman',
        createdAt: 1));
    rssId = rss.id!;
    twitterId = tw.id!;
    await db.insertArticleIfNew(Article(
        sourceId: rssId,
        guid: 'a1',
        title: 'Brussels news',
        url: 'https://bx1/a1',
        contentMarkdown: 'body',
        read: 1,
        createdAt: 10,
        fetched: 1));
    await db.insertArticleIfNew(Article(
        sourceId: twitterId,
        guid: 't1',
        title: 'a tweet',
        contentMarkdown: 'tweet body',
        createdAt: 11,
        fetched: 1));
    final article = (await db.getArticles(sourceId: rssId)).single;
    await db.insertHighlight(Highlight(
        articleId: article.id!, text: 'kept passage', createdAt: 12));
  });

  test('storage is namespaced per profile', () async {
    expect((await db.getSources()).length, 2);
    expect((await db.getHighlights()).length, 1);

    // Another profile sees an empty library.
    db.activeProfile = 'p2';
    expect(await db.getSources(), isEmpty);
    expect(await db.getArticles(), isEmpty);
    expect(await db.getHighlights(), isEmpty);
    expect((await db.search('kept')).highlights, isEmpty);
    expect(await db.unreadCountsBySource(), isEmpty);

    // URL dedup is per profile too: the same story can exist in both.
    final mine = await db.insertSource(Source(
        type: SourceType.rss, title: 'Mine', url: 'https://mine',
        createdAt: 2));
    expect(
        await db.insertArticleIfNew(Article(
            sourceId: mine.id!,
            guid: 'x1',
            title: 'Same story',
            url: 'https://bx1/a1',
            createdAt: 13)),
        isTrue,
        reason: "profile A's copy must not block profile B's");

    // Built-in sources are per profile (distinct url suffix).
    final saved = await db.ensureSavedLinksSource();
    expect(saved.url, isNot(AppDatabase.savedLinksUrl));
    db.activeProfile = 'default';
    final savedDefault = await db.ensureSavedLinksSource();
    expect(savedDefault.url, AppDatabase.savedLinksUrl);
    expect(savedDefault.id, isNot(saved.id));
  });

  test('importProfileData copies selected feeds with their highlights',
      () async {
    db.activeProfile = 'p3';
    // Customize: only the RSS feed, not the twitter one.
    final imported = await db.importProfileData(
        fromProfile: 'default', onlySourceIds: {rssId});
    expect(imported, 1);

    final sources = await db.getSources();
    expect(sources.map((s) => s.title), ['BX1']);
    final articles = await db.getArticles();
    expect(articles.map((a) => a.title), ['Brussels news']);
    expect(articles.single.read, 1, reason: 'read state travels along');
    final highlights = await db.getHighlights();
    expect(highlights.single.text, 'kept passage');
    expect(highlights.single.articleId, articles.single.id,
        reason: 'highlight remapped to the copied article');

    // The original profile is untouched.
    db.activeProfile = 'default';
    expect((await db.getSources()).length, greaterThanOrEqualTo(2));
    expect((await db.getHighlights()).length, 1);
  });

  test('reconcileShares pulls relay-only shares into the local record',
      () async {
    SharedPreferences.setMockInitialValues({});
    ProfileService.instance.debugResetActiveCache();
    db.activeProfile = 'default';
    final service = ProfileService.instance;
    await service.createIdentity();

    // Two local highlights; one already recorded as shared (without an
    // event id), one shared long ago — only on the relays.
    final article = (await db.getArticles(sourceId: rssId)).first;
    await db.insertHighlight(Highlight(
        articleId: article.id!, text: 'old relay-only share', createdAt: 5));
    final highlights = await db.getHighlights();
    final oldShare = highlights
        .firstWhere((h) => h.text == 'old relay-only share');
    final recorded =
        highlights.firstWhere((h) => h.text == 'kept passage');
    await db.insertShare(Share(
        highlightId: recorded.id!, medium: 'profile', createdAt: 10));

    service.debugFetchHighlightEvents = (pubkey) async => [
          {
            'id': 'e1' * 32,
            'content': 'old relay-only share',
            'created_at': 1700000000,
          },
          {
            'id': 'e2' * 32,
            'content': 'kept passage',
            'created_at': 1700000100,
          },
          {
            'id': 'e3' * 32,
            'content': 'someone elses highlight',
            'created_at': 1700000200,
          },
        ];
    final added = await service.reconcileShares();
    expect(added, 1, reason: 'only the relay-only share is new');

    final shares = await db.getShares();
    final reconciled = shares
        .firstWhere((s) => s.highlightId == oldShare.id);
    expect(reconciled.medium, 'profile');
    expect(reconciled.ref, 'e1' * 32, reason: 'event id attached');
    expect(reconciled.createdAt, 1700000000 * 1000);
    // The pre-existing share gained its missing event id.
    expect(
        shares
            .firstWhere((s) => s.highlightId == recorded.id)
            .ref,
        'e2' * 32);

    // Idempotent: a second pass adds nothing.
    expect(await service.reconcileShares(), 0);
    service.debugFetchHighlightEvents = null;
  });

  test('published highlights carry the NIP-89 client tag', () async {
    SharedPreferences.setMockInitialValues({});
    ProfileService.instance.debugResetActiveCache();
    final service = ProfileService.instance;
    await service.createIdentity();
    Map<String, dynamic>? published;
    service.debugPublish = (event) async {
      published = event;
      return 1;
    };
    await service.publishHighlight(
      const Article(
          sourceId: 1, guid: 'g', title: 'T', createdAt: 0),
      const Highlight(articleId: 1, text: 'quote', createdAt: 0),
    );
    expect(published!['tags'],
        anyElement(equals(['client', 'einkreader'])));
  });
}
