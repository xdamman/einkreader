// The Read tab lists articles by when they were read, not by publication
// date — and day headers follow the reading time too.
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/screens/home_screen.dart';
import 'package:einkreader/services/sync_service.dart';
import 'package:einkreader/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SyncService.instance.autoSyncOnLaunch = false;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_readorder').path,
        'test.db');
    final source = await db.insertSource(Source(
        type: SourceType.rss, title: 'Feed', url: 'https://x', createdAt: 0));
    final now = DateTime.now();
    Future<void> add(String title, DateTime published, DateTime? readAt) =>
        db.insertArticleIfNew(Article(
          sourceId: source.id!,
          guid: title,
          title: title,
          contentMarkdown: 'Body',
          publishedAt: published.millisecondsSinceEpoch,
          createdAt: 0,
          fetched: 1,
          read: 1,
          readAt: readAt?.millisecondsSinceEpoch,
        ));
    // Published long ago, read just now → first, under Today.
    await add('Old essay read today', DateTime(2020, 1, 1), now);
    // Published yesterday, read an hour before the old essay.
    await add('Fresh news read earlier',
        now.subtract(const Duration(days: 1)),
        now.subtract(const Duration(hours: 1)));
  });

  testWidgets('Read tab orders by reading time', (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: buildEinkTheme(), home: const HomeScreen()));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    final oldY = tester.getTopLeft(find.text('Old essay read today')).dy;
    final freshY = tester.getTopLeft(find.text('Fresh news read earlier')).dy;
    expect(oldY, lessThan(freshY));
    expect(find.text('2020'), findsNothing);
    expect(find.textContaining('WEDNESDAY, JANUARY 1'), findsNothing,
        reason: 'headers follow the reading date, not publication');
  });

  test('marking read records the time; unread clears it', () async {
    final a = (await db.getArticles()).first;
    await db.markArticleRead(a.id!, read: false);
    expect((await db.getArticle(a.id!))!.readAt, isNull);
    final before = DateTime.now().millisecondsSinceEpoch;
    await db.markArticleRead(a.id!);
    expect((await db.getArticle(a.id!))!.readAt,
        greaterThanOrEqualTo(before));
  });
}
