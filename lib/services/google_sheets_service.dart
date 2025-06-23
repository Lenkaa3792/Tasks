import 'dart:io'; // For SocketException
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:http/http.dart' as http;
import 'package:truefam_contribution_tracker/models/contribution_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:truefam_contribution_tracker/services/logging_service.dart';

const String _sheetUrlKey = 'google_sheet_url';

class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();

  GoogleAuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _client.send(request);
  }
}

class GoogleSheetsService {
  final GoogleSignIn _googleSignIn;
  final LoggingService _logger;
  sheets.SheetsApi? _sheetsApi;

  GoogleSheetsService(this._googleSignIn, this._logger);

  Future<bool> initialize() async {
    if (_googleSignIn.currentUser == null) {
      _logger.warning("GoogleSheetsService: User not signed in. Cannot initialize.");
      _sheetsApi = null;
      return false;
    }

    try {
      final headers = await _googleSignIn.currentUser!.authHeaders;
      final client = GoogleAuthClient(headers);
      _sheetsApi = sheets.SheetsApi(client);
      _logger.info("GoogleSheetsService: Initialized successfully for user ${_googleSignIn.currentUser!.email}.");
      return true;
    } on SocketException catch (e,s) {
      _logger.error("GoogleSheetsService: Network error during initialization.", errorObject: e, stackTrace: s);
      _sheetsApi = null;
      return false;
    }
    catch (e, s) {
      _logger.error("GoogleSheetsService: Error initializing Sheets API.", errorObject: e, stackTrace: s);
      _sheetsApi = null;
      return false;
    }
  }

  Future<String?> _getSpreadsheetId() async {
    final prefs = await SharedPreferences.getInstance();
    final sheetUrl = prefs.getString(_sheetUrlKey);
    if (sheetUrl == null || sheetUrl.isEmpty) {
      _logger.warning("GoogleSheetsService: Sheet URL not configured.");
      return null;
    }

    final uri = Uri.tryParse(sheetUrl);
    if (uri != null && uri.pathSegments.length >= 3 && uri.pathSegments[0] == 'spreadsheets' && uri.pathSegments[1] == 'd') {
      return uri.pathSegments[2];
    } else {
      _logger.error("GoogleSheetsService: Could not parse Spreadsheet ID from URL: $sheetUrl. Example format: https://docs.google.com/spreadsheets/d/YOUR_SPREADSHEET_ID/edit");
      return null;
    }
  }

  Future<bool> appendContribution(Contribution contribution, {String sheetName = 'Sheet1'}) async {
    if (!await ensureApiInitialized()) return false;

    final spreadsheetId = await _getSpreadsheetId();
    if (spreadsheetId == null) {
      _logger.error("GoogleSheetsService: Spreadsheet ID is null. Cannot append.");
      return false;
    }

    final valueRange = sheets.ValueRange.fromJson({'values': [contribution.toSheetRow()]});

    try {
      final result = await _sheetsApi!.spreadsheets.values.append(
        valueRange,
        spreadsheetId,
        '$sheetName!A1',
        valueInputOption: 'USER_ENTERED',
        insertDataOption: 'INSERT_ROWS',
      );
      _logger.success("GoogleSheetsService: Successfully appended to sheet for ${contribution.senderName}. Updates: ${result.updates?.updatedCells}");
      return true;
    } on SocketException catch (e,s) {
       _logger.error("GoogleSheetsService: Network error appending to sheet for ${contribution.senderName}.", errorObject: e, stackTrace: s);
       return false;
    } catch (e, s) {
      _logger.error("GoogleSheetsService: Error appending to sheet for ${contribution.senderName}.", errorObject: e, stackTrace: s);
      if (e is sheets.DetailedApiRequestError) {
          _logger.warning("GoogleSheetsService: API Error ${e.statusCode}. Message: ${e.message}");
          if (e.statusCode == 401 || e.statusCode == 403) {
            _logger.warning("Authentication error during append. Forcing API re-initialization on next call.");
            _sheetsApi = null;
          } else if (e.statusCode == 404) {
            _logger.error("Sheet or range not found. Check Sheet URL and name ('$sheetName').");
          }
      }
      return false;
    }
  }

  Future<List<List<Object?>>?> getSheetData({String sheetName = 'Sheet1', String range = 'A:E'}) async {
    if (!await ensureApiInitialized()) return null;

    final spreadsheetId = await _getSpreadsheetId();
    if (spreadsheetId == null) {
      _logger.error("GoogleSheetsService: Spreadsheet ID is null. Cannot read data.");
      return null;
    }

    final String readRange = '$sheetName!$range';
    _logger.info("GoogleSheetsService: Reading data from sheet '$spreadsheetId', range '$readRange'");

    try {
      final result = await _sheetsApi!.spreadsheets.values.get(spreadsheetId, readRange);
      _logger.success("GoogleSheetsService: Successfully read ${result.values?.length ?? 0} rows from sheet.");
      return result.values;
    } on SocketException catch (e,s) {
       _logger.error("GoogleSheetsService: Network error reading from sheet.", errorObject: e, stackTrace: s);
       return null;
    } catch (e, s) {
      _logger.error("GoogleSheetsService: Error reading from sheet.", errorObject: e, stackTrace: s);
       if (e is sheets.DetailedApiRequestError) {
          _logger.warning("GoogleSheetsService: API Error ${e.statusCode}. Message: ${e.message}");
          if (e.statusCode == 401 || e.statusCode == 403) {
            _logger.warning("Authentication error during read. Forcing API re-initialization on next call.");
            _sheetsApi = null;
          } else if (e.statusCode == 404) {
            _logger.error("Sheet or range not found. Check Sheet URL and name ('$sheetName', range '$range').");
          }
      }
      return null;
    }
  }

  Future<bool> ensureApiInitialized() async {
     if (_sheetsApi == null) {
      _logger.info("GoogleSheetsService: Sheets API not initialized. Attempting to re-initialize.");
      if (!await initialize()) {
        _logger.error("GoogleSheetsService: Re-initialization failed.");
        return false;
      }
    }
    return true;
  }

  Future<bool> ensureAuthenticated() async {
    if (_googleSignIn.currentUser == null) {
      _logger.warning("GoogleSheetsService: No user signed in for ensureAuthenticated.");
      return false;
    }
    return initialize();
  }
}
