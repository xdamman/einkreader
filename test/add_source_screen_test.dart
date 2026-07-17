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

  testWidgets('shows RSS, Twitter and Nostr sections', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildEinkTheme(),
      home: const AddSourceScreen(),
    ));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(find.text('RSS feed'), findsOneWidget);
    expect(find.text('Feed or website URL'), findsOneWidget);
    expect(find.text('Twitter / X'), findsOneWidget);
    expect(find.text('Connect Twitter'), findsOneWidget);
    expect(find.text('Nostr'), findsOneWidget);
    expect(find.text('npub'), findsOneWidget);
  });
}
