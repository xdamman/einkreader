// Email-to-feed: at sync the app pulls emails sent to name@einkreader.app
// (server-converted to Markdown, whitelisted sender only), turns each into
// an article under the built-in Email source — link-mostly emails behave
// like tweets (linked page downloaded, email kept as intro) — and
// acknowledges processed items.
import 'dart:convert';
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/services/archive_store.dart';
import 'package:einkreader/services/plugin_service.dart';
import 'package:einkreader/services/profile_service.dart';
import 'package:einkreader/services/sync_service.dart';
import 'package:einkreader/services/twitter_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase.instance;
  late Directory tmp;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    tmp = Directory.systemTemp.createTempSync('einkreader_email');
    db.debugDatabasePath = p.join(tmp.path, 'test.db');
    ArchiveStore.instance.debugConfigure(basePath: p.join(tmp.path, 'a'));
    await ProfileService.instance.createIdentity();
    // A registered username enables the inbox fetch.
    ProfileService.instance.debugHttpClient = MockClient(
        (request) async => http.Response(jsonEncode({'ok': true}), 200));
    await ProfileService.instance.registerUsername('xavier');
    ProfileService.instance.debugHttpClient = null;
    // Inbound email is the Email plugin.
    await PluginService.instance.setEmailOn(true);
  });

  test('registerUsername carries the accepted senders', () async {
    Map<String, dynamic>? body;
    ProfileService.instance.debugHttpClient = MockClient((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'ok': true}), 200);
    });
    await ProfileService.instance
        .setAllowedSenders(['Me@Example.COM', 'friend@example.org']);
    expect(body!['senders'], ['me@example.com', 'friend@example.org'],
        reason: 'a change re-registers with the normalized addresses');
    await ProfileService.instance.addAllowedSender('friend@example.org');
    expect(await ProfileService.instance.allowedSenders,
        ['me@example.com', 'friend@example.org'],
        reason: 'no duplicates');
    ProfileService.instance.debugHttpClient = null;
  });

  test("the sender's note: link lines and link cards removed, words kept",
      () {
    const link = 'https://news.example/story';
    expect(SyncService.emailNote('Check this: $link', link), 'Check this:');
    // A mail app's shared-article card: nothing of the sender's own.
    expect(
        SyncService.emailNote(
            '[\n\n[Is Belgium heading back?]($link)\n\n'
                    '[news.example]($link)\n\n]($link)\n\n---\n\n'
                    '![photo.jpg](https://blob/photo.jpg)',
            link),
        isEmpty);
    expect(SyncService.emailNote('I loved [this piece]($link) a lot', link),
        'I loved this piece a lot');
  });

  test('inbox items become Email articles; processed ones are acked',
      () async {
    List<String>? acked;
    final client = MockClient((request) async {
      final url = request.url.toString();
      if (url == 'https://einkreader.app/api/inbox' &&
          request.method == 'GET') {
        expect(request.headers['Authorization'], startsWith('Nostr '));
        return http.Response(
            jsonEncode({
              'items': [
                {'id': 'inbox/pk/1.json', 'url': 'https://blob/1.json'},
                {'id': 'inbox/pk/2.json', 'url': 'https://blob/2.json'},
              ]
            }),
            200);
      }
      if (url == 'https://blob/1.json') {
        // Substantial email with an image attachment: it IS the article.
        return http.Response(
            jsonEncode({
              'subject': 'Sunday letter',
              'from': 'me@example.com',
              'markdown': '# Hello\n\n${'A long paragraph. ' * 60}\n\n'
                  '![photo](https://blob/photo.jpg)',
              'url': null,
              'receivedAt': 1700000000000,
            }),
            200);
      }
      if (url == 'https://blob/2.json') {
        // Link-mostly email: behaves like a tweet (page downloaded later).
        return http.Response(
            jsonEncode({
              'subject': 'Worth a read',
              'from': 'me@example.com',
              'markdown': 'Check this: https://example.com/essay',
              'url': 'https://example.com/essay',
              'receivedAt': 1700000001000,
            }),
            200);
      }
      if (url == 'https://blob/photo.jpg') {
        return http.Response.bytes([137, 80, 78, 71], 200,
            headers: {'content-type': 'image/png'});
      }
      if (url == 'https://einkreader.app/api/inbox' &&
          request.method == 'DELETE') {
        acked = (jsonDecode(request.body)['ids'] as List).cast<String>();
        return http.Response(jsonEncode({'deleted': acked!.length}), 200);
      }
      // The linked essay download attempt (pending-content pass).
      return http.Response('nope', 404);
    });
    // The archive downloads attachment images with its own client.
    ArchiveStore.instance
        .debugConfigure(basePath: p.join(tmp.path, 'a'), client: client);
    final sync = SyncService.forTest(
      http: client,
      twitter: TwitterService(
          accessToken: () async => 't', client: MockClient((r) async {
        return http.Response('{}', 200);
      })),
    )..autoSyncOnLaunch = false;

    await sync.syncAll();

    final source = (await db.getSources())
        .firstWhere((s) => s.type == SourceType.email);
    final articles = await db.getArticles(sourceId: source.id);
    expect(articles, hasLength(2));

    final letter = articles.firstWhere((a) => a.title == 'Sunday letter');
    expect(letter.author, 'me@example.com');
    expect(letter.fetched, 1, reason: 'substantial email IS the content');
    expect(letter.contentMarkdown, contains('# Hello'));
    expect(letter.contentMarkdown, contains('eink-img://'),
        reason: 'attachment image localized for offline reading');

    final linked = articles.firstWhere((a) => a.title == 'Worth a read');
    expect(linked.url, 'https://example.com/essay');
    expect(linked.summary, contains('Check this'));

    expect(acked, containsAll(['inbox/pk/1.json', 'inbox/pk/2.json']));

    // A second sync inserts nothing new (guid dedupe) even if the server
    // still listed the items.
    await sync.syncAll();
    expect(await db.getArticles(sourceId: source.id), hasLength(2));
  });

  test('mail from a new sender waits as a request until accepted',
      () async {
    final deleted = <String>[];
    final client = MockClient((request) async {
      final url = request.url.toString();
      if (url == 'https://einkreader.app/api/inbox' &&
          request.method == 'GET') {
        return http.Response(
            jsonEncode({
              'items': [
                {'id': 'inbox/pk/request-3.json', 'url': 'https://blob/3.json'},
                {'id': 'inbox/pk/request-4.json', 'url': 'https://blob/4.json'},
              ]
                  .where((i) => !deleted.contains(i['id']))
                  .toList()
            }),
            200);
      }
      if (url == 'https://blob/3.json' || url == 'https://blob/4.json') {
        final n = url.contains('3') ? '3' : '4';
        return http.Response(
            jsonEncode({
              'subject': 'To read $n',
              'from': 'stranger$n@example.net',
              'markdown': 'https://example.com/story$n',
              'url': 'https://example.com/story$n',
              'receivedAt': 1700000002000,
              'request': true,
            }),
            200);
      }
      if (url == 'https://einkreader.app/api/inbox' &&
          request.method == 'DELETE') {
        deleted.addAll(
            (jsonDecode(request.body)['ids'] as List).cast<String>());
        return http.Response('{}', 200);
      }
      return http.Response('nope', 404);
    });
    ProfileService.instance.debugHttpClient = MockClient(
        (request) async => http.Response(jsonEncode({'ok': true}), 200));
    addTearDown(() => ProfileService.instance.debugHttpClient = null);
    final sync = SyncService.forTest(
      http: client,
      twitter: TwitterService(
          accessToken: () async => 't',
          client: MockClient((r) async => http.Response('{}', 200))),
    )..autoSyncOnLaunch = false;

    await sync.syncAll();
    expect(sync.emailRequests.map((r) => r.from),
        ['stranger3@example.net', 'stranger4@example.net']);
    Future<List<String>> titles() async =>
        (await db.getArticles()).map((a) => a.title).toList();
    expect(await titles(), isNot(contains('To read 3')),
        reason: 'not in the Inbox until accepted');
    expect(deleted, isEmpty, reason: 'requests are kept server-side');

    await sync.acceptEmailRequest(sync.emailRequests.first);
    expect(await titles(), contains('To read 3'));
    expect(await ProfileService.instance.allowedSenders,
        contains('stranger3@example.net'));
    expect(deleted, ['inbox/pk/request-3.json']);

    await sync.deleteEmailRequest(sync.emailRequests.single);
    expect(sync.emailRequests, isEmpty);
    expect(deleted, contains('inbox/pk/request-4.json'));
    expect(await titles(), isNot(contains('To read 4')));
  });
}
