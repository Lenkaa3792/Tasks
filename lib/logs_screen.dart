import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:truefam_contribution_tracker/models/log_entry_model.dart';
import 'package:truefam_contribution_tracker/services/logging_service.dart'; // Using global logger instance

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final DateFormat _logTimestampFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

  @override
  void initState() {
    super.initState();
    // Add listener to rebuild the screen when logs change
    logger.addListener(_onLogsChanged);
  }

  @override
  void dispose() {
    // Remove listener to prevent memory leaks
    logger.removeListener(_onLogsChanged);
    super.dispose();
  }

  void _onLogsChanged() {
    if (mounted) {
      setState(() {}); // Trigger a rebuild
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Application Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear Logs',
            onPressed: () {
              // Show confirmation dialog before clearing
              showDialog(
                context: context,
                builder: (BuildContext context) {
                  return AlertDialog(
                    title: const Text('Clear Logs?'),
                    content: const Text('Are you sure you want to delete all log entries? This action cannot be undone.'),
                    actions: <Widget>[
                      TextButton(
                        child: const Text('Cancel'),
                        onPressed: () {
                          Navigator.of(context).pop();
                        },
                      ),
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: Colors.red),
                        child: const Text('Clear All'),
                        onPressed: () {
                          logger.clearLogs();
                          Navigator.of(context).pop();
                        },
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
      body: logger.logs.isEmpty
          ? const Center(child: Text('No log entries yet.'))
          : ListView.separated(
              padding: const EdgeInsets.all(8.0),
              itemCount: logger.logs.length,
              itemBuilder: (context, index) {
                final logEntry = logger.logs[index];
                return ListTile(
                  leading: Icon(logEntry.icon, color: logEntry.color, size: 28),
                  title: Text(
                    logEntry.message,
                    style: TextStyle(color: logEntry.color.shade700, fontSize: 14),
                  ),
                  subtitle: Text(
                    _logTimestampFormat.format(logEntry.timestamp),
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                );
              },
              separatorBuilder: (context, index) => const Divider(height: 1),
            ),
    );
  }
}
