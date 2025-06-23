import 'package:flutter/material.dart';
import 'package:truefam_contribution_tracker/services/google_sheets_service.dart';
import 'package:truefam_contribution_tracker/services/logging_service.dart'; // Using global logger
import 'package:provider/provider.dart'; // Assuming Provider for GoogleSignIn state if needed, or pass directly

// For this screen, we'll assume GoogleSheetsService is accessible,
// possibly via Provider or passed as an argument.
// For simplicity here, I might make it accessible if SettingsScreen makes it so,
// or expect it to be passed. Given current structure, it's tied to GoogleSignIn instance.

class SheetDataScreen extends StatefulWidget {
  final GoogleSheetsService googleSheetsService;

  const SheetDataScreen({super.key, required this.googleSheetsService});

  @override
  State<SheetDataScreen> createState() => _SheetDataScreenState();
}

class _SheetDataScreenState extends State<SheetDataScreen> {
  List<List<Object?>>? _sheetData;
  bool _isLoading = false;
  String? _error;
  List<String> _columnHeaders = ["Sender Name", "Amount (\$)", "Member ID", "Date", "Source"]; // Default headers

  @override
  void initState() {
    super.initState();
    _fetchSheetData();
  }

  Future<void> _fetchSheetData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final data = await widget.googleSheetsService.getSheetData();
      if (data != null && data.isNotEmpty) {
        // Assuming the first row might be headers, let's check
        // For now, we'll use predefined headers as per spec, but skip first row if it matches
        if (_isHeaderRow(data.first)) {
            _columnHeaders = data.first.map((e) => e.toString()).toList();
            _sheetData = data.sublist(1); // Data without header row
             logger.info("SheetDataScreen: Headers extracted from sheet: $_columnHeaders");
        } else {
            _sheetData = data; // Data might not have headers or they don't match
            logger.info("SheetDataScreen: Using predefined headers. First data row: ${data.first}");
        }

      } else {
        _sheetData = [];
         logger.info("SheetDataScreen: No data or empty data returned from sheet.");
      }
    } catch (e, s) {
      _error = "Failed to load sheet data. Check logs.";
      logger.error("SheetDataScreen: Error fetching sheet data.", errorObject: e, stackTrace: s);
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  bool _isHeaderRow(List<Object?> row) {
    if (row.length < 2) return false; // Minimal check
    // A more robust check would compare against expected header names case-insensitively
    final lowerCaseRow = row.map((e) => e.toString().toLowerCase()).toList();
    return lowerCaseRow.contains("sender name") ||
           lowerCaseRow.contains("amount") ||
           lowerCaseRow.contains("member id");
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sheet Data Viewer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh Data',
            onPressed: _isLoading ? null : _fetchSheetData,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 16)),
              const SizedBox(height: 10),
              ElevatedButton(onPressed: _fetchSheetData, child: const Text('Retry'))
            ],
          ),
        ),
      );
    }
    if (_sheetData == null || _sheetData!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('No data to display or sheet is empty.', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 10),
            ElevatedButton(onPressed: _fetchSheetData, child: const Text('Fetch Data'))
            ],
        ),
      );
    }

    // Ensure all rows have the same number of columns as headers for DataTable
    final int numColumns = _columnHeaders.length;
    final List<List<Object?>> displayData = _sheetData!.map((row) {
        List<Object?> fullRow = List.from(row);
        while(fullRow.length < numColumns) {
            fullRow.add(''); // Pad with empty strings if row is shorter
        }
        return fullRow.sublist(0, numColumns); // Truncate if row is longer
    }).toList();


    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: _columnHeaders.map((header) => DataColumn(label: Text(header, style: const TextStyle(fontWeight: FontWeight.bold)))).toList(),
          rows: displayData.map((row) {
            return DataRow(
              cells: row.map((cell) => DataCell(Text(cell?.toString() ?? ''))).toList(),
            );
          }).toList(),
          columnSpacing: 20,
          headingRowHeight: 48,
          dataRowMinHeight: 40,
          dataRowMaxHeight: 48,
          border: TableBorder.all(width: 1.0, color: Colors.grey.shade300),
        ),
      ),
    );
  }
}
