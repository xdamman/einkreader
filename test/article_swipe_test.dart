// Verifies swipe navigation on the article screen (book convention):
//   swipe left   -> next article in the feed
//   swipe right  -> previous article
//   swipe right at the first-opened article -> back to the feed
import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/article_screen.dart';
import 'package:einkreader/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<int> ids; // feed order: [A, B, C]

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await databaseFactory.deleteDatabase(
        p.join(await databaseFactory.getDatabasesPath(), 'einkreader.db'));

    final db = AppDatabase.instance;
    final source = await db.insertSource(Source(
        type: SourceType.rss, title: 'Feed', url: 'https://x', createdAt: 0));
    // Newest first: A(300) > B(200) > C(100), matching the feed's ordering.
    for (final spec in [('A', 300), ('B', 200), ('C', 100)]) {
      await db.insertArticleIfNew(Article(
        sourceId: source.id!,
        guid: 'guid-${spec.$1}',
        title: 'Article ${spec.$1}',
        contentMarkdown: 'Body of ${spec.$1}',
        publishedAt: spec.$2,
        createdAt: spec.$2,
        fetched: 1,
      ));
    }
    ids = [for (final a in await db.getArticles()) a.id!];
    expect(ids.length, 3);
  });

  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  Future<void> swipe(WidgetTester tester, {required bool right}) async {
    await tester.fling(
      find.byKey(const Key('articleSwipe')),
      Offset(right ? 400 : -400, 0),
      1200,
    );
    await settle(tester);
  }

  testWidgets('swipe left/right navigate the feed; right at start returns',
      (tester) async {
    // A feed sentinel that opens Article A (index 0) on tap, so we can detect
    // the pop back to the feed.
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ArticleScreen(
                        articleId: ids[0],
                        articleIds: ids,
                        initialIndex: 0,
                      ))),
              child: const Text('FEED'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('FEED'));
    await settle(tester);

    // Opened at A.
    expect(find.text('Article A'), findsWidgets);
    expect(find.text('FEED'), findsNothing);

    // Swipe left → B → C, and stays at C past the end.
    await swipe(tester, right: false);
    expect(find.text('Article B'), findsWidgets);
    expect(find.text('Article A'), findsNothing);

    await swipe(tester, right: false);
    expect(find.text('Article C'), findsWidgets);

    await swipe(tester, right: false); // past the end: no-op
    expect(find.text('Article C'), findsWidgets);

    // Swipe right → B → A (the first-opened one).
    await swipe(tester, right: true);
    expect(find.text('Article B'), findsWidgets);

    await swipe(tester, right: true);
    expect(find.text('Article A'), findsWidgets);
    expect(find.text('FEED'), findsNothing);

    // Swipe right at the first-opened article → back to the feed.
    await swipe(tester, right: true);
    expect(find.text('FEED'), findsOneWidget);
  });

  testWidgets('two-finger double tap (e-ink refresh gesture) is not a swipe',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: ArticleScreen(
        articleId: ids[0],
        articleIds: ids,
        initialIndex: 0,
      ),
    ));
    await settle(tester);
    expect(find.text('Article A'), findsWidgets);

    // The AINOTE's screen-refresh gesture: two horizontally separated fingers
    // tapping twice in quick succession. The cross-finger up/down deltas used
    // to read as an instant horizontal fling.
    final box = tester.getCenter(find.byKey(const Key('articleSwipe')));
    for (var tap = 0; tap < 2; tap++) {
      final finger1 = await tester.startGesture(box + const Offset(-60, 0));
      final finger2 = await tester.startGesture(box + const Offset(60, 0));
      await tester.pump(const Duration(milliseconds: 30));
      await finger1.up();
      await finger2.up();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await settle(tester);

    // Still on Article A: no navigation happened.
    expect(find.text('Article A'), findsWidgets);
    expect(find.text('Article B'), findsNothing);
  });
}
