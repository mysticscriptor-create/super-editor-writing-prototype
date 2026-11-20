import 'package:flutter/material.dart';

import 'src/ui/editor_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ScribePrototypeApp());
}

class ScribePrototypeApp extends StatelessWidget {
  const ScribePrototypeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scribe SuperEditor Prototype',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1D4ED8),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const EditorScreen(),
    );
  }
}
