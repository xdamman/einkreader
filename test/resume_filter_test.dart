// The Resume reading section lives below the Feed tab's filter strip and
// obeys it: selecting a source narrows the half-read list to that source.
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
        Directory.systemTemp.createTempSync('einkreader_resume').path,
        'test.db');

    for (final name in ['Alpha', 'Beta']) {
      final source = await db.insertSource(Source(
          type: SourceType.rss,
          title: name,
          url: 'https://$name.example',
          createdAt: 0));
      await db.insertArticleIfNew(Article(
        sourceId: source.id!,
        guid: 'half-$name',
        title: 'Half-read $name story',
        contentMarkdown: 'Body',
        publishedAt: 100,
        createdAt: 100,
        fetched: 1,
      ));
    }
    for (final article in await db.getArticles()) {
      await db.saveScrollPosition(article.id!, 100);
    }
  });

  Future<void> settle(WidgetTester tester) async {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  testWidgets('resume reading sits below the filters and follows them',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: const HomeScreen(key: ValueKey('resume-filter')),
    ));
    await settle(tester);

    // Both half-read stories appear under Resume reading…
    expect(find.text('Half-read Alpha story'), findsWidgets);
    expect(find.text('Half-read Beta story'), findsWidgets);
    // …and the section header sits below the chip strip.
    final chipY = tester.getTopLeft(find.text('All').first).dy;
    final headerY = tester.getTopLeft(find.text('RESUME READING')).dy;
    expect(headerY, greaterThan(chipY),
        reason: 'the section moved below the filter rows');

    // Selecting a source narrows the resume list to it.
    await tester.tap(find.text('Beta').first);
    await settle(tester);
    expect(find.text('Half-read Alpha story'), findsNothing);
    expect(find.text('Half-read Beta story'), findsWidgets);
  });
}
