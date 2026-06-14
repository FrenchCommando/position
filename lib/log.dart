import 'package:flutter_riverpod/flutter_riverpod.dart';

enum LogLevel { info, warn, error }

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String message;
  const LogEntry(this.time, this.level, this.message);
}

/// In-app activity log — relay publishes/acks, key adoption, received positions,
/// errors. Newest first, capped. Lives in memory only (cleared on restart).
final logProvider = NotifierProvider<LogController, List<LogEntry>>(LogController.new);

class LogController extends Notifier<List<LogEntry>> {
  static const _cap = 300;

  @override
  List<LogEntry> build() => const [];

  void add(String message, {LogLevel level = LogLevel.info}) {
    final next = [LogEntry(DateTime.now(), level, message), ...state];
    state = next.length > _cap ? next.sublist(0, _cap) : next;
  }

  void clear() => state = const [];
}
