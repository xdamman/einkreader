import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/archive_store.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Resolve the offline archive directory up front so stored images render on
  // a cold start, before any sync runs.
  await ArchiveStore.instance.ensureInitialized();
  runApp(const EinkReaderApp());
}

class EinkReaderApp extends StatelessWidget {
  const EinkReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'eink reader',
      debugShowCheckedModeBanner: false,
      theme: buildEinkTheme(),
      home: const HomeScreen(),
    );
  }
}
