import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
