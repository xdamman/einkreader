// The Add source screen offers all three kinds in one place: an RSS feed
// (URL or domain), a Twitter account, and a Nostr npub.
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/screens/add_source_screen.dart';
import 'package:einkreader/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    AppDatabase.instance.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_add_source').path,
        'test.db');
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  testWidgets('first asks only for the kind of source', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: const AddSourceScreen(),
    ));
    await settle(tester);

    expect(find.text('What would you like to add?'), findsOneWidget);
    for (final kind in ['RSS feed', 'X (Twitter)', 'Nostr']) {
      expect(find.text(kind), findsOneWidget);
    }
    // No forms on the first level.
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('each kind opens its own screen', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: const AddSourceScreen(),
    ));
    await settle(tester);

    await tester.tap(find.text('RSS feed'));
    await settle(tester);
    expect(find.text('Add RSS feed'), findsOneWidget);
    expect(find.text('Feed or website URL'), findsOneWidget);
    expect(find.text('Connect Twitter'), findsNothing);
    await tester.pageBack();
    await settle(tester);

    await tester.tap(find.text('X (Twitter)'));
    await settle(tester);
    expect(find.text('Connect Twitter'), findsOneWidget);
    expect(find.text('Feed or website URL'), findsNothing);
    await tester.pageBack();
    await settle(tester);

    await tester.tap(find.text('Nostr'));
    await settle(tester);
    expect(find.text('Follow someone'), findsOneWidget);
    expect(find.text('npub'), findsOneWidget);
  });
}
