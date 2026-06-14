import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'log.dart';

class LogScreen extends ConsumerWidget {
  const LogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(logProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear',
            onPressed: entries.isEmpty ? null : () => ref.read(logProvider.notifier).clear(),
          ),
        ],
      ),
      body: entries.isEmpty
          ? const Center(child: Text('No activity yet.'))
          : ListView.separated(
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => _tile(entries[i]),
            ),
    );
  }

  Widget _tile(LogEntry e) {
    final (icon, color) = switch (e.level) {
      LogLevel.info => (Icons.info_outline, Colors.blueGrey),
      LogLevel.warn => (Icons.warning_amber, Colors.orange),
      LogLevel.error => (Icons.error_outline, Colors.red),
    };
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(icon, color: color, size: 18),
      title: Text(e.message, style: const TextStyle(fontSize: 13)),
      trailing: Text(_clock(e.time), style: const TextStyle(fontSize: 11, color: Colors.grey)),
    );
  }

  static String _clock(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
