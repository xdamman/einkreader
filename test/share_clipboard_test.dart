// Two quick ways to queue any URL to read later:
//   - text shared into the app (Android share sheet): first URL extracted,
//     surrounding text kept as a title hint
//   - a URL sitting in the clipboard when the app opens: a slim dismissible
//     bar offers to save it, and never re-prompts for a handled URL
import 'dart:io';

import 'package:einkreader/db/app_database.dart';
import 'package:einkreader/models.dart';
import 'package:einkreader/services/share_service.dart';
import 'package:einkreader/widgets/clipboard_link_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase.instance;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    db.debugDatabasePath = p.join(
        Directory.systemTemp.createTempSync('einkreader_share').path,
        'test.db');
    // Open the database here, in real async: a first open inside a widget
    // test's fake-async zone never completes.
    await db.getArticles();
  });

  group('ShareLinkService.parse', () {
    test('extracts a bare URL', () {
      final link = ShareLinkService.parse('https://example.com/story')!;
      expect(link.url, 'https://example.com/story');
      expect(link.title, isNull);
    });

    test('keeps surrounding text as the title hint', () {
      final link = ShareLinkService.parse(
          'A Great Read\nhttps://example.com/story?id=1')!;
      expect(link.url, 'https://example.com/story?id=1');
      expect(link.title, 'A Great Read');
    });

    test('drops trailing sentence punctuation', () {
      final link =
          ShareLinkService.parse('Look at https://example.com/story.')!;
      expect(link.url, 'https://example.com/story');
    });

    test('returns null without a URL', () {
      expect(ShareLinkService.parse('no links here'), isNull);
      expect(ShareLinkService.parse(null), isNull);
    });
  });

  group('ClipboardLinkPrompt', () {
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }

    void mockClipboard(WidgetTester tester, String? text) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          // An empty clipboard is a null response, not {'text': null}.
          return text == null ? null : {'text': text};
        }
        return null;
      });
    }

    Future<void> pumpPrompt(WidgetTester tester,
        {required List<Article> savedOut}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: ClipboardLinkPrompt(onSaved: savedOut.add),
        ),
      ));
      await settle(tester);
    }

    testWidgets('offers a copied URL and queues it on Read later',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      mockClipboard(tester, 'https://example.com/clipped');
      final saved = <Article>[];
      await pumpPrompt(tester, savedOut: saved);

      expect(find.textContaining('example.com/clipped'), findsOneWidget);
      await tester.tap(find.text('Read later'));
      await settle(tester);

      expect(find.textContaining('example.com/clipped'), findsNothing);
      expect(saved, hasLength(1));
      expect(saved.single.readLater, 1);
      expect(saved.single.fetched, 0);
      final source =
          (await tester.runAsync(() => db.getSource(saved.single.sourceId)))!;
      expect(source.type, SourceType.savedLinks);
    });

    testWidgets('a dismissed URL never prompts again', (tester) async {
      SharedPreferences.setMockInitialValues({});
      mockClipboard(tester, 'https://example.com/ignored');
      await pumpPrompt(tester, savedOut: []);
      expect(find.textContaining('example.com/ignored'), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await settle(tester);
      expect(find.textContaining('example.com/ignored'), findsNothing);

      // Fresh instance (relaunch): still silent for the same URL.
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpPrompt(tester, savedOut: []);
      expect(find.textContaining('example.com/ignored'), findsNothing);
    });

    testWidgets('ignores prose, already-saved URLs and empty clipboards',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      mockClipboard(tester, 'read https://example.com/inline in a sentence');
      await pumpPrompt(tester, savedOut: []);
      expect(find.byIcon(Icons.link), findsNothing);

      // Already in the library → no prompt.
      await tester.runAsync(
          () => db.saveLinkForLater(url: 'https://example.com/clipped'));
      mockClipboard(tester, 'https://example.com/clipped');
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpPrompt(tester, savedOut: []);
      expect(find.byIcon(Icons.link), findsNothing);

      mockClipboard(tester, null);
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpPrompt(tester, savedOut: []);
      expect(find.byIcon(Icons.link), findsNothing);
    });
  });
}
