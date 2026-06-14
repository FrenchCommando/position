import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'map_screen.dart';

void main() {
  runApp(const ProviderScope(child: PositionApp()));
}

class PositionApp extends StatelessWidget {
  const PositionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Position',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF7C3AED), useMaterial3: true),
      home: const MapScreen(),
    );
  }
}
