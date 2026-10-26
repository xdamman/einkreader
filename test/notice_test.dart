import 'dart:io';

import 'package:einkreader/widgets/notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<BuildContext> pumpApp(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (c) {
        context = c;
        return const SizedBox.expand();
      })),
    ));
    return context;
  }

  testWidgets('a notice with an Undo goes away by itself after 5 seconds',
      (tester) async {
    final context = await pumpApp(tester);
    var undone = false;
    showNotice(context, '3 articles marked as seen',
        action: SnackBarAction(label: 'Undo', onPressed: () => undone = true));
    await tester.pumpAndSettle();
    expect(find.text('3 articles marked as seen'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('3 articles marked as seen'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('3 articles marked as seen'), findsNothing);
    expect(undone, isFalse);
  });

  testWidgets('a plain notice also goes away after 5 seconds', (tester) async {
    final context = await pumpApp(tester);
    showNotice(context, 'Url copied');
    await tester.pumpAndSettle();
    await tester.pump(kNoticeDuration);
    await tester.pumpAndSettle();
    expect(find.text('Url copied'), findsNothing);
  });

  testWidgets('a new notice replaces the one on screen', (tester) async {
    final context = await pumpApp(tester);
    showNotice(context, 'First');
    await tester.pumpAndSettle();
    showNotice(context, 'Second');
    await tester.pumpAndSettle();
    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
  });

  test('every bottom-of-screen message goes through showNotice', () {
    final offenders = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.endsWith('notice.dart'))
        .where((f) => f.readAsStringSync().contains('.showSnackBar('))
        .map((f) => f.path)
        .toList();
    expect(offenders, isEmpty,
        reason: 'use showNotice so every notice behaves the same way');
  });
}
