import 'package:flutter/foundation.dart'; // For ChangeNotifier
import 'package:truefam_contribution_tracker/models/log_entry_model.dart';
import 'dart:collection'; // For UnmodifiableListView

class LoggingService extends ChangeNotifier {
  final List<LogEntry> _logs = [];
  final int maxLogs = 200; // Limit the number of logs stored

  // Provide an unmodifiable view of the logs
  UnmodifiableListView<LogEntry> get logs => UnmodifiableListView(_logs);

  void addLog(String message, {LogLevel level = LogLevel.info}) {
    final entry = LogEntry(message: message, level: level);

    // Print to console as well, useful for debugging when UI is not visible
    debugPrint("[${level.toString().split('.').last.toUpperCase()}] ${entry.timestamp}: ${entry.message}");

    _logs.insert(0, entry); // Add to the beginning to show newest first
    if (_logs.length > maxLogs) {
      _logs.removeLast(); // Remove oldest log if limit is exceeded
    }
    notifyListeners(); // Notify UI listeners
  }

  void clearLogs() {
    _logs.clear();
    addLog("Logs cleared.", level: LogLevel.warning);
    notifyListeners();
  }

  // Convenience methods
  void info(String message) => addLog(message, level: LogLevel.info);
  void success(String message) => addLog(message, level: LogLevel.success);
  void warning(String message) => addLog(message, level: LogLevel.warning);
  void error(String message, {Object? errorObject, StackTrace? stackTrace}) {
    String fullMessage = message;
    if (errorObject != null) {
        fullMessage += "\nError: ${errorObject.toString()}";
    }
    if (stackTrace != null && kDebugMode) { // Only show stack trace in debug mode for brevity in release logs
        fullMessage += "\nStackTrace: $stackTrace";
    }
    addLog(fullMessage, level: LogLevel.error);
  }

}

// Simple global accessor for the LoggingService
// For a larger app, consider using Provider or GetIt for dependency injection.
final LoggingService logger = LoggingService();
