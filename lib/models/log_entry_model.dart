import 'package:flutter/material.dart';

enum LogLevel { info, warning, error, success }

class LogEntry {
  final DateTime timestamp;
  final String message;
  final LogLevel level;

  LogEntry({
    required this.message,
    this.level = LogLevel.info,
  }) : timestamp = DateTime.now();

  Color get color {
    switch (level) {
      case LogLevel.info:
        return Colors.blueGrey;
      case LogLevel.success:
        return Colors.green;
      case LogLevel.warning:
        return Colors.orange;
      case LogLevel.error:
        return Colors.red;
      default:
        return Colors.black;
    }
  }

  IconData get icon {
     switch (level) {
      case LogLevel.info:
        return Icons.info_outline;
      case LogLevel.success:
        return Icons.check_circle_outline;
      case LogLevel.warning:
        return Icons.warning_amber_outlined;
      case LogLevel.error:
        return Icons.error_outline;
      default:
        return Icons.help_outline;
    }
  }
}
