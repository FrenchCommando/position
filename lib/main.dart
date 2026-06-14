import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'background_task.dart';
import 'log_screen.dart';
import 'map_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureBackgroundService();
  runApp(const ProviderScope(child: PositionApp()));
}

class PositionApp extends StatelessWidget {
  const PositionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Position',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF7C3AED), useMaterial3: true),
      home: const RootScreen(),
    );
  }
}

/// Map + Logs tabs. Both stay alive in an IndexedStack so switching to Logs and
/// back doesn't tear down the map or its relay subscriptions.
class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [MapScreen(), LogScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Map'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Logs'),
        ],
      ),
    );
  }
}
