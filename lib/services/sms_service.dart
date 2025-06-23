import 'package:telephony/telephony.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';
import 'package:truefam_contribution_tracker/models/contribution_model.dart';
import 'package:truefam_contribution_tracker/services/logging_service.dart';

/// Type definition for the callback when a new contribution is successfully parsed.
typedef ContributionCallback = void Function(Contribution contribution);
/// Type definition for the callback when SMS permission is denied.
typedef PermissionDeniedCallback = void Function();

/// Handles SMS listening, permission requests, and parsing of various payment notifications.
class SmsService {
  final Telephony telephony = Telephony.instance;
  final LoggingService _logger; // Service for logging application events.
  bool _hasPermissions = false; // Tracks if SMS permission is granted.
  ContributionCallback? onContributionReceived; // Callback for successfully parsed contributions.
  PermissionDeniedCallback? onPermissionDenied; // Callback for permission denial.
  DateTime? _startDateFilter; // Optional start date for filtering messages.
  DateTime? _endDateFilter; // Optional end date for filtering messages.

  // Regex for Zelle: "Zelle: You received $20.00 from John Doe on 07/25/2025. Memo: 784293."
  final RegExp _zelleSmsRegex = RegExp(
    r"Zelle: You received \$?(?<amount>[0-9,]+\.[0-9]{2}) from (?<name>.*?) on (?<date>\d{2}/\d{2}/\d{4})\. Memo: (?<memo>\d+)",
    caseSensitive: false,
  );
  // Regex for Venmo: "Venmo: Mary Kamau paid you $20.00 – "918245" on 07/25/2025."
  final RegExp _venmoSmsRegex = RegExp(
    r"Venmo: (?<name>.*?) paid you \$?(?<amount>[0-9,]+\.[0-9]{2}) – ""(?<memo>\d+)"" on (?<date>\d{2}/\d{2}/\d{4})",
    caseSensitive: false,
  );
  // Regex for Cash App: "Cash App: You received $20.00 from Carlos Diaz on 07/25/2025. Note: 675312."
  final RegExp _cashAppSmsRegex = RegExp(
    r"Cash App: You received \$?(?<amount>[0-9,]+\.[0-9]{2}) from (?<name>.*?) on (?<date>\d{2}/\d{2}/\d{4})\. Note: (?<memo>\d+)",
    caseSensitive: false,
  );
  // Regex for M-Pesa: "M-PESA: Confirmed. You have received Ksh 2,500 from Jane Mwangi on 25/07/2025 at 10:45 AM. Acc. No: 918245."
  final RegExp _mpesaSmsRegex = RegExp(
    r"M-PESA: Confirmed. You have received Ksh ?(?<amount>[0-9,]+(\.[0-9]{2})?) from (?<name>.*?) on (?<date>\d{2}/\d{2}/\d{4}) at .* Acc\. No: (?<memo>\d+)",
    caseSensitive: false,
  );

  SmsService(this._logger);

  /// Initializes the SMS service, requests permissions, and starts listening if granted.
  ///
  /// [callback] is invoked when a contribution is parsed.
  /// [startDate] and [endDate] define the optional monitoring period.
  /// [permissionDeniedCallback] is invoked if SMS permissions are not granted.
  Future<void> initialize(
    ContributionCallback callback, {
    DateTime? startDate,
    DateTime? endDate,
    PermissionDeniedCallback? permissionDeniedCallback,
  }) async {
    onContributionReceived = callback;
    onPermissionDenied = permissionDeniedCallback;
    _startDateFilter = startDate;
    _endDateFilter = endDate;
    _logger.info("SMS Service: Initializing. Date filter Start: $_startDateFilter, End: $_endDateFilter");
    await _requestPermissions();
    if (_hasPermissions) {
      _startListening();
    } else {
      _logger.warning("SMS Service: Permissions not granted. SMS listening will not start.");
      onPermissionDenied?.call();
    }
  }

  /// Updates the date range for filtering messages.
  void setDateRange({DateTime? startDate, DateTime? endDate}) {
    _startDateFilter = startDate;
    _endDateFilter = endDate;
    _logger.info("SMS Service: Date filter updated. Start: $_startDateFilter, End: $_endDateFilter");
  }

  /// Requests SMS permissions from the user.
  /// Updates `_hasPermissions` and logs the outcome.
  Future<bool> _requestPermissions() async {
    _logger.info("SMS Service: Requesting SMS permissions...");
    var status = await Permission.sms.status;
    if (status.isDenied) {
        status = await Permission.sms.request();
    }

    _hasPermissions = status.isGranted;

    if (status.isGranted) {
      _logger.info("SMS permission granted.");
    } else if (status.isDenied) {
      _logger.warning("SMS permission denied by user.");
    } else if (status.isPermanentlyDenied) {
      _logger.error("SMS permission permanently denied. User must enable in settings.");
    }
    return _hasPermissions;
  }

  /// Public method to allow re-requesting or checking SMS permissions, e.g., from the UI.
  Future<bool> checkAndRequestPermissions() async {
    return await _requestPermissions();
  }

  /// Starts listening for incoming SMS messages.
  void _startListening() {
    telephony.listenIncomingSms(
      onNewMessage: (SmsMessage message) {
        _logger.info("SMS Service: New SMS received: ${message.body?.substring(0, (message.body?.length ?? 0) > 50 ? 50 : message.body?.length)}...");
        _parseMessage(message);
      },
      onBackgroundMessage: _onBackgroundSms, // Must be a top-level or static function
      listenInBackground: true,
    );
    _logger.info("SMS Service: Started listening for incoming SMS.");
  }

  /// Static handler for background SMS messages (required by telephony plugin).
  /// Note: Cannot directly use instance logger here.
  static void _onBackgroundSms(SmsMessage message) {
    // This function runs in a separate isolate. For robust background logging or processing,
    // communication with the main isolate (e.g., via SendPort/ReceivePort) would be needed.
    print("SMS Service (Background): New SMS: ${message.body}"); // Basic print for background
  }

  /// Parses the body of an [SmsMessage] to extract contribution details.
  void _parseMessage(SmsMessage message) {
    if (message.body == null) {
      _logger.warning("SMS Service: Received SMS with null body.");
      return;
    }
    String smsBody = message.body!;
    Contribution? contribution;

    /// Internal helper to attempt parsing with a given regex and parameters.
    Contribution? tryParse(RegExp regex, String sourceName, String currency, DateFormat dateFormat) {
      Match? match = regex.firstMatch(smsBody);
      if (match == null) return null;

      try {
        String amountStr = match.namedGroup('amount')!.replaceAll(',', '');
        double amount = double.parse(amountStr);
        String name = match.namedGroup('name')!.trim();
        String dateStr = match.namedGroup('date')!;
        String memo = match.namedGroup('memo')!.trim();
        DateTime parsedTransactionDate = dateFormat.parse(dateStr);

        // Note: Primary date filtering (using _startDateFilter, _endDateFilter)
        // is handled in SettingsScreen._handleContributionReceived after parsing.
        // This service focuses on the parsing itself.

        return Contribution(
          senderName: name, amount: amount, memberId: memo, date: parsedTransactionDate,
          source: sourceName, originalMessage: smsBody, currency: currency,
        );
      } catch (e, s) {
        _logger.error("SMS Service: Error parsing $sourceName SMS.", errorObject: e, stackTrace: s);
        _logger.info("Original $sourceName SMS for error: $smsBody"); // Log full body on error
        return null;
      }
    }

    // Attempt to parse with each known format
    contribution = tryParse(_zelleSmsRegex, 'SMS (Zelle)', 'USD', DateFormat('MM/dd/yyyy'));
    contribution ??= tryParse(_venmoSmsRegex, 'SMS (Venmo)', 'USD', DateFormat('MM/dd/yyyy'));
    contribution ??= tryParse(_cashAppSmsRegex, 'SMS (CashApp)', 'USD', DateFormat('MM/dd/yyyy'));
    contribution ??= tryParse(_mpesaSmsRegex, 'SMS (M-Pesa)', 'KSH', DateFormat('dd/MM/yyyy'));

    if (contribution != null) {
      _logger.success("SMS Service: Parsed Contribution: ${contribution.senderName} - ${contribution.amount}");
      onContributionReceived?.call(contribution);
    } else {
      // Log only a snippet if no parser matched, to avoid overly verbose logs for spam etc.
      _logger.info("SMS Service: No parser matched for SMS: ${smsBody.substring(0, smsBody.length > 100 ? 100 : smsBody.length)}...");
    }
  }

  /// Simulates receiving an SMS for testing purposes.
  void simulateSmsReceive(String body, String sender) {
    _logger.info("SMS Service: Simulating SMS receive from $sender: $body");
    final SmsMessage simulatedMessage = SmsMessage(
      address: sender, body: body, date: DateTime.now().millisecondsSinceEpoch,
      dateSent: DateTime.now().millisecondsSinceEpoch, id: DateTime.now().millisecondsSinceEpoch,
      read: false, status: MessageStatus.RECEIVED, threadId: 1, type: SmsType.MESSAGE_TYPE_INBOX,
    );
    _parseMessage(simulatedMessage);
  }
}
