import 'dart:convert'; // For base64 decoding
import 'dart:io'; // For SocketException
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/gmail/v1.dart' as gmail;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:truefam_contribution_tracker/models/contribution_model.dart';
import 'package:truefam_contribution_tracker/services/logging_service.dart';

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

typedef EmailContributionCallback = void Function(Contribution contribution);

class EmailService {
  final GoogleSignIn _googleSignIn;
  final LoggingService _logger;
  gmail.GmailApi? _gmailApi;
  EmailContributionCallback? onContributionReceived;
  DateTime? _startDateFilter;
  DateTime? _endDateFilter;

  final DateFormat _monthDayYearFormat = DateFormat('MMMM d, yyyy');

  final RegExp _zelleEmailSubjectRegex = RegExp(r"You’ve received money from (?<name>.*)", caseSensitive: false);
  final RegExp _zelleEmailBodyRegex = RegExp(
      r"(?<name_body>.*?) has sent you \$?(?<amount>[0-9,]+\.[0-9]{2}) with Zelle® on (?<date>January|February|March|April|May|June|July|August|September|October|November|December)\s\d{1,2},\s\d{4}\.\s*Memo: (?<memo>\d+)",
      caseSensitive: false, multiLine: true);

  final RegExp _venmoEmailSubjectRegex = RegExp(r"(?<name>.*?) sent you \$?(?<amount>[0-9,]+\.[0-9]{2})", caseSensitive: false);
  final RegExp _venmoEmailBodyRegex = RegExp(r"Note: (?<memo>\d+)", caseSensitive: false, multiLine: true);

  final RegExp _cashAppEmailSubjectRegex = RegExp(r"Payment Received - \$?(?<amount>[0-9,]+\.[0-9]{2}) from (?<name>.*)", caseSensitive: false);
  final RegExp _cashAppEmailBodyRegex = RegExp(
      r"You’ve received \$?[0-9,]+\.[0-9]{2} from (?<name_body>.*?) on (?<date>January|February|March|April|May|June|July|August|September|October|November|December)\s\d{1,2},\s\d{4}\.\s*(?:Cashtag: .*?\s*)?Note: (?<memo>\d+)",
      caseSensitive: false, multiLine: true);

  EmailService(this._googleSignIn, this._logger);

  Future<bool> initialize(EmailContributionCallback callback, {DateTime? startDate, DateTime? endDate}) async {
    onContributionReceived = callback;
    _startDateFilter = startDate;
    _endDateFilter = endDate;
    if (_googleSignIn.currentUser == null) {
      _logger.warning("EmailService: User not signed in. Cannot initialize Gmail API.");
      _gmailApi = null; // Ensure API is null if user logs out
      return false;
    }
    try {
      final headers = await _googleSignIn.currentUser!.authHeaders;
      final client = GoogleAuthClient(headers);
      _gmailApi = gmail.GmailApi(client);
      _logger.info("EmailService: Gmail API initialized successfully. Date filter Start: $_startDateFilter, End: $_endDateFilter");
      return true;
    } on SocketException catch (e,s) {
      _logger.error("EmailService: Network error during initialization.", errorObject: e, stackTrace: s);
      _gmailApi = null;
      return false;
    }
    catch (e, s) {
      _logger.error("EmailService: Error initializing Gmail API.", errorObject: e, stackTrace: s);
      _gmailApi = null;
      return false;
    }
  }

  void setDateRange({DateTime? startDate, DateTime? endDate}) {
    _startDateFilter = startDate;
    _endDateFilter = endDate;
    _logger.info("EmailService: Date filter updated. Start: $_startDateFilter, End: $_endDateFilter");
  }

  Future<void> fetchAndParseEmails({String query = 'Zelle OR Venmo OR "Cash App" "Payment Received"'}) async {
    if (!await _ensureApiInitialized()) return;

    String dateQueryPart = "";
    if (_startDateFilter != null) {
      dateQueryPart += " after:${DateFormat('yyyy/MM/dd').format(_startDateFilter!)}";
    }
    if (_endDateFilter != null) {
      dateQueryPart += " before:${DateFormat('yyyy/MM/dd').format(_endDateFilter!.add(const Duration(days: 1)))}";
    }

    final String finalQuery = query + dateQueryPart;
    _logger.info("EmailService: Fetching emails with final query: $finalQuery");

    try {
      final response = await _gmailApi!.users.messages.list('me', q: finalQuery, maxResults: 50);
      if (response.messages == null || response.messages!.isEmpty) {
        _logger.info("EmailService: No emails found matching query '$finalQuery'.");
        return;
      }

      _logger.info("EmailService: Found ${response.messages!.length} potential emails.");
      int processedCount = 0;
      for (var messageHeader in response.messages!) {
        if (messageHeader.id == null) continue;
        final message = await _gmailApi!.users.messages.get('me', messageHeader.id!, format: 'FULL');
        if (_parseEmailMessage(message)) {
          processedCount++;
        }
      }
      _logger.info("EmailService: Processed $processedCount contribution(s) from fetched emails.");
    } on SocketException catch (e,s) {
       _logger.error("EmailService: Network error fetching emails.", errorObject: e, stackTrace: s);
    } catch (e, s) {
      _logger.error("EmailService: Error fetching emails.", errorObject: e, stackTrace: s);
       if (e is gmail.DetailedApiRequestError) {
          _logger.warning("EmailService: API Error ${e.statusCode}. Message: ${e.message}");
          if (e.statusCode == 401 || e.statusCode == 403) {
            _logger.warning("Authentication error during fetch. Forcing API re-initialization on next call.");
            _gmailApi = null;
          }
      }
    }
  }

  Future<bool> _ensureApiInitialized() async {
     if (_gmailApi == null) {
      _logger.info("EmailService: Gmail API not initialized. Attempting to re-initialize.");
      if (!await initialize(onContributionReceived!, startDate: _startDateFilter, endDate: _endDateFilter)) {
          _logger.error("EmailService: Re-initialization failed.");
          return false;
      }
    }
    return true;
  }


  bool _parseEmailMessage(gmail.Message message) {
    String? subject;
    DateTime? emailReceivedDate;

    message.payload?.headers?.forEach((header) {
      if (header.name?.toLowerCase() == 'subject') subject = header.value;
      if (header.name?.toLowerCase() == 'date') {
         if (header.value != null) {
            try {
              emailReceivedDate = DateFormat("EEE, dd MMM yyyy HH:mm:ss Z").parse(header.value!);
            } catch(e) {
               try { emailReceivedDate = DateFormat("dd MMM yyyy HH:mm:ss Z").parse(header.value!);}
               catch (e2) { _logger.warning("EmailService: Could not parse email date string: ${header.value}");}
            }
         }
      }
    });

    if (subject == null) {
      _logger.warning("EmailService: Email message ID ${message.id} has no subject. Skipping.");
      return false;
    }
    emailReceivedDate ??= DateTime.now();

    String? body = _extractTextPlainBody(message);
    if (body == null) {
      body = message.snippet;
      if (body != null) _logger.info("EmailService: Using snippet as body for email ID ${message.id}");
    }
    if (body == null) {
      _logger.warning("EmailService: Could not extract text/plain body or snippet for email ID ${message.id}");
      return false;
    }

    Contribution? contribution;

    Match? zelleSubjMatch = _zelleEmailSubjectRegex.firstMatch(subject);
    if (zelleSubjMatch != null) {
      Match? zelleBodyMatch = _zelleEmailBodyRegex.firstMatch(body);
      if (zelleBodyMatch != null) {
        try {
          String name = zelleSubjMatch.namedGroup('name')!.trim();
          String amountStr = zelleBodyMatch.namedGroup('amount')!.replaceAll(',', '');
          double amount = double.parse(amountStr);
          String memo = zelleBodyMatch.namedGroup('memo')!.trim();
          String dateStr = zelleBodyMatch.namedGroup('date')!;
          DateTime date = _monthDayYearFormat.parse(dateStr);
          contribution = Contribution(
            senderName: name, amount: amount, memberId: memo, date: date,
            source: 'Email (Zelle)', originalMessage: "Subject: $subject\n\n$body", currency: 'USD',
          );
        } catch (e,s) {
          _logger.error("EmailService: Error parsing Zelle email content (ID: ${message.id})", errorObject: e, stackTrace: s);
        }
      }
    }

    if (contribution == null) {
      Match? venmoSubjMatch = _venmoEmailSubjectRegex.firstMatch(subject);
      if (venmoSubjMatch != null) {
        Match? venmoBodyMatch = _venmoEmailBodyRegex.firstMatch(body);
        if (venmoBodyMatch != null) {
          try {
            String name = venmoSubjMatch.namedGroup('name')!.trim();
            String amountStr = venmoSubjMatch.namedGroup('amount')!.replaceAll(',', '');
            double amount = double.parse(amountStr);
            String memo = venmoBodyMatch.namedGroup('memo')!.trim();
            DateTime date = emailReceivedDate!;
            contribution = Contribution(
              senderName: name, amount: amount, memberId: memo, date: date,
              source: 'Email (Venmo)', originalMessage: "Subject: $subject\n\n$body", currency: 'USD',
            );
          } catch (e,s) {
            _logger.error("EmailService: Error parsing Venmo email content (ID: ${message.id})", errorObject: e, stackTrace: s);
          }
        }
      }
    }

    if (contribution == null) {
      Match? cashAppSubjMatch = _cashAppEmailSubjectRegex.firstMatch(subject);
      if (cashAppSubjMatch != null) {
        Match? cashAppBodyMatch = _cashAppEmailBodyRegex.firstMatch(body);
        if (cashAppBodyMatch != null) {
          try {
            String name = cashAppSubjMatch.namedGroup('name')!.trim();
            String amountStr = cashAppSubjMatch.namedGroup('amount')!.replaceAll(',', '');
            double amount = double.parse(amountStr);
            String memo = cashAppBodyMatch.namedGroup('memo')!.trim();
            String dateStr = cashAppBodyMatch.namedGroup('date')!;
            DateTime date = _monthDayYearFormat.parse(dateStr);
            contribution = Contribution(
              senderName: name, amount: amount, memberId: memo, date: date,
              source: 'Email (CashApp)', originalMessage: "Subject: $subject\n\n$body", currency: 'USD',
            );
          } catch (e,s) {
            _logger.error("EmailService: Error parsing Cash App email content (ID: ${message.id})", errorObject: e, stackTrace: s);
          }
        }
      }
    }

    if (contribution != null) {
      _logger.success("EmailService: Parsed Email Contribution: ${contribution.senderName} - ${contribution.amount}");
      onContributionReceived?.call(contribution);
      return true;
    }
    return false;
  }

  String? _extractTextPlainBody(gmail.Message message) {
    if (message.payload?.parts != null) {
      for (var part in message.payload!.parts!) {
        if (part.mimeType == 'text/plain' && part.body?.data != null) {
          try { return utf8.decode(base64Url.decode(part.body!.data!)); }
          catch (e) { _logger.error("Error decoding base64 body part", errorObject: e); }
        }
        if (part.parts != null) {
          for (var subPart in part.parts!) {
             if (subPart.mimeType == 'text/plain' && subPart.body?.data != null) {
                try { return utf8.decode(base64Url.decode(subPart.body!.data!)); }
                catch (e) { _logger.error("Error decoding base64 sub-body part", errorObject: e); }
             }
          }
        }
      }
    } else if (message.payload?.body?.data != null && message.payload?.mimeType == 'text/plain') {
      try { return utf8.decode(base64Url.decode(message.payload!.body!.data!)); }
      catch (e) { _logger.error("Error decoding base64 main body", errorObject: e); }
    }
    return null;
  }

  void simulateEmailParse({
    required String subject, required String bodyContent, required String fromAddress,
    required DateTime emailDate, required String type,
  }) {
    _logger.info("EmailService: Simulating $type Email Parse for Subject: $subject");
    final dummyMessage = gmail.Message()
      ..id = "dummy_email_${type}_${DateTime.now().millisecondsSinceEpoch}"
      ..snippet = bodyContent.length > 100 ? bodyContent.substring(0,100) : bodyContent
      ..payload = (gmail.MessagePart()
        ..headers = [
          gmail.MessagePartHeader()..name="Subject"..value=subject,
          gmail.MessagePartHeader()..name="From"..value=fromAddress,
          gmail.MessagePartHeader()..name="Date"..value=DateFormat("EEE, dd MMM yyyy HH:mm:ss Z").format(emailDate.toUtc()),
        ]
        ..mimeType = "text/plain"
        ..body = (gmail.MessagePartBody()..data = base64Url.encode(utf8.encode(bodyContent)))
      );
    _parseEmailMessage(dummyMessage);
  }
}
