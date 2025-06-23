import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:truefam_contribution_tracker/models/contribution_model.dart';
import 'package:truefam_contribution_tracker/services/sms_service.dart';
import 'package:truefam_contribution_tracker/services/email_service.dart';
import 'package:truefam_contribution_tracker/services/google_sheets_service.dart';
import 'package:truefam_contribution_tracker/services/logging_service.dart';
import 'package:truefam_contribution_tracker/logs_screen.dart';
import 'package:truefam_contribution_tracker/sheet_data_screen.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart'; // For openAppSettings

const List<String> scopes = <String>[
  'email',
  'https://www.googleapis.com/auth/gmail.readonly',
  'https://www.googleapis.com/auth/spreadsheets',
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _sheetUrlController = TextEditingController();
  final _secureStorage = const FlutterSecureStorage();
  GoogleSignInAccount? _currentUser;
  String? _googleAuthError;
  bool _isLoading = false;
  bool _isProcessing = false;
  bool _smsPermissionPermanentlyDenied = false;

  static const String _sheetUrlKey = 'google_sheet_url';
  static const String _startDateKey = 'monitoring_start_date';
  static const String _endDateKey = 'monitoring_end_date';

  DateTime? _selectedStartDate;
  DateTime? _selectedEndDate;

  late final GoogleSignIn _googleSignIn;
  late final GoogleSheetsService _googleSheetsService;
  late final SmsService _smsService;
  late final EmailService _emailService;

  final List<Contribution> _parsedContributions = [];
  final Set<String> _processedTransactionIds = {};
  static const String _processedTransactionsKey = 'processed_transactions';


  @override
  void initState() {
    super.initState();
    logger.info("SettingsScreen: Initializing...");
    _googleSignIn = GoogleSignIn(scopes: scopes);
    _googleSheetsService = GoogleSheetsService(_googleSignIn, logger);
    _smsService = SmsService(logger);
    _emailService = EmailService(_googleSignIn, logger);

    _loadSavedSettings();
    _checkInitialSmsPermission();


    _googleSignIn.onCurrentUserChanged.listen((GoogleSignInAccount? account) async {
      logger.info("SettingsScreen: Google User changed to ${account?.email ?? 'null'}");
      setState(() => _currentUser = account);
      if (account != null) {
        await _storeTokens(account);
        await _googleSheetsService.initialize();
        await _emailService.initialize(_handleContributionReceived, startDate: _selectedStartDate, endDate: _selectedEndDate);
      } else {
        await _clearTokens();
        _googleSheetsService.initialize();
        _emailService.initialize(_handleContributionReceived, startDate: _selectedStartDate, endDate: _selectedEndDate);
      }
    });
    _googleSignIn.signInSilently().then((account) async {
      if (account != null) {
        logger.info("SettingsScreen: Silent sign-in successful for ${account.email}");
        await _googleSheetsService.initialize();
        await _emailService.initialize(_handleContributionReceived, startDate: _selectedStartDate, endDate: _selectedEndDate);
      } else {
        logger.info("SettingsScreen: No user for silent sign-in.");
      }
    });
    // SMS Service initialization moved to after _checkInitialSmsPermission or on explicit user action
  }

  Future<void> _checkInitialSmsPermission() async {
    final status = await Permission.sms.status;
    if (status.isPermanentlyDenied) {
      setState(() => _smsPermissionPermanentlyDenied = true);
    }
    // Initialize SMS service only if not permanently denied, or let user trigger it.
    // For now, it's initialized in _loadSavedSettings -> _initializeSmsService flow.
    // We can make it more explicit if needed.
    if (!status.isPermanentlyDenied) {
        _initializeSmsService(); // Initialize if not permanently denied
    } else {
        logger.error("SettingsScreen: SMS permission permanently denied. SMS service not started automatically.");
    }
  }


  Future<void> _loadSavedSettings() async {
    logger.info("SettingsScreen: Loading saved settings...");
    final prefs = await SharedPreferences.getInstance();
    final sheetUrl = prefs.getString(_sheetUrlKey);
    if (sheetUrl != null) {
      _sheetUrlController.text = sheetUrl;
      logger.info("Loaded sheet URL: $sheetUrl");
    }

    final startDateMillis = prefs.getInt(_startDateKey);
    if (startDateMillis != null) {
      _selectedStartDate = DateTime.fromMillisecondsSinceEpoch(startDateMillis);
      logger.info("Loaded start date: $_selectedStartDate");
    }
    final endDateMillis = prefs.getInt(_endDateKey);
    if (endDateMillis != null) {
      _selectedEndDate = DateTime.fromMillisecondsSinceEpoch(endDateMillis);
      logger.info("Loaded end date: $_selectedEndDate");
    }

    final processedIds = prefs.getStringList(_processedTransactionsKey);
    if (processedIds != null) {
        _processedTransactionIds.addAll(processedIds);
        logger.info("Loaded ${_processedTransactionIds.length} processed transaction IDs.");
    }
    _updateServicesWithDateRange();
    setState(() {});
  }

  Future<void> _saveProcessedTransactionId(String id) async {
    _processedTransactionIds.add(id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_processedTransactionsKey, _processedTransactionIds.toList());
    logger.info("Saved transaction ID: $id. Total: ${_processedTransactionIds.length}");
  }

  String _generateTransactionId(Contribution c) {
    final datePart = DateFormat('yyyyMMdd').format(c.date);
    return "${c.source}_${c.senderName}_${c.amount.toStringAsFixed(2)}_${datePart}_${c.memberId}";
  }

  Future<void> _handleContributionReceived(Contribution contribution) async {
    logger.info("SettingsScreen: Received contribution: ${contribution.senderName} from ${contribution.source}");
    if (_selectedStartDate != null && contribution.date.isBefore(_selectedStartDate!)) {
      logger.warning("Contribution from ${contribution.senderName} on ${contribution.date} is before start date $_selectedStartDate. Skipping.");
      return;
    }
    if (_selectedEndDate != null && contribution.date.isAfter(_selectedEndDate!.add(const Duration(days: 1)))) {
      logger.warning("Contribution from ${contribution.senderName} on ${contribution.date} is after end date $_selectedEndDate. Skipping.");
      return;
    }

    final transactionId = _generateTransactionId(contribution);
    if (_processedTransactionIds.contains(transactionId)) {
        logger.warning("Duplicate transaction detected: $transactionId. Skipping.");
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Duplicate: ${contribution.senderName} already processed.'), backgroundColor: Colors.orange)
        );
        return;
    }

    setState(() {
      _parsedContributions.add(contribution);
      _isProcessing = true;
    });
    logger.info("Processing contribution: ${contribution.senderName}. Attempting to upload...");
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Parsed ${contribution.source}: ${contribution.senderName} - ${contribution.currency} ${contribution.amount}. Uploading...')),
    );
    bool success = await _googleSheetsService.appendContribution(contribution);

    if (success) {
      await _saveProcessedTransactionId(transactionId);
      logger.success("Successfully uploaded ${contribution.senderName}'s contribution to Google Sheet!");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Uploaded to Sheet!'), backgroundColor: Colors.green)
      );
    } else {
       logger.error("Failed to upload ${contribution.senderName}'s contribution.");
       ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to upload ${contribution.source}. Check logs.'), backgroundColor: Colors.red)
      );
    }
    if(mounted) setState(() => _isProcessing = false);
  }

  void _handleSmsPermissionDenied() {
    logger.warning("SettingsScreen: SMS Permission was denied by SmsService callback.");
    if(mounted){
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: const Text('SMS permission is required to read messages. Please grant permission.'),
                action: SnackBarAction(
                    label: 'Settings',
                    onPressed: () {
                        openAppSettings();
                    },
                ),
                duration: const Duration(seconds: 10),
            ),
        );
        // Check if it's permanently denied to update UI accordingly
        Permission.sms.status.then((status) {
            if(status.isPermanentlyDenied && mounted) {
                setState(() => _smsPermissionPermanentlyDenied = true);
            }
        });
    }
}


  Future<void> _initializeSmsService() async {
    logger.info("SettingsScreen: Initializing SMS service...");
    await _smsService.initialize(
        _handleContributionReceived,
        startDate: _selectedStartDate,
        endDate: _selectedEndDate,
        permissionDeniedCallback: _handleSmsPermissionDenied,
    );
  }

  void _updateServicesWithDateRange() {
    logger.info("SettingsScreen: Updating services with date range. Start: $_selectedStartDate, End: $_selectedEndDate");
    _smsService.setDateRange(startDate: _selectedStartDate, endDate: _selectedEndDate);
    _emailService.setDateRange(startDate: _selectedStartDate, endDate: _selectedEndDate);
  }

  Future<void> _saveSheetUrl() async {
    if (_sheetUrlController.text.isEmpty || !_sheetUrlController.text.startsWith("https://docs.google.com/spreadsheets/d/")) {
      logger.warning("Attempted to save invalid sheet URL: ${_sheetUrlController.text}");
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a valid Google Sheet URL')));
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sheetUrlKey, _sheetUrlController.text);
    logger.success("Google Sheet URL saved: ${_sheetUrlController.text}");
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Google Sheet URL saved!')));
  }

  Future<void> _selectDate(BuildContext context, bool isStartDate) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: (isStartDate ? _selectedStartDate : _selectedEndDate) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2101),
    );
    if (picked != null) {
      logger.info("Date selected: $picked for ${isStartDate ? 'start' : 'end'} date.");
      setState(() {
        if (isStartDate) {
          _selectedStartDate = picked;
        } else {
          if (_selectedStartDate != null && picked.isBefore(_selectedStartDate!)) {
             logger.warning("End date $picked cannot be before start date $_selectedStartDate.");
             ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('End date cannot be before start date.')));
             return;
          }
          _selectedEndDate = picked;
        }
      });
      final prefs = await SharedPreferences.getInstance();
      if (isStartDate) {
        await prefs.setInt(_startDateKey, picked.millisecondsSinceEpoch);
      } else {
        await prefs.setInt(_endDateKey, picked.millisecondsSinceEpoch);
      }
      _updateServicesWithDateRange();
    } else {
      logger.info("Date selection cancelled for ${isStartDate ? 'start' : 'end'} date.");
    }
  }

  Future<void> _handleSignIn() async {
    logger.info("SettingsScreen: Initiating Google Sign-In...");
    setState(() => _isLoading = true);
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) {
        logger.warning('Google Sign-in cancelled by user.');
        if(mounted) setState(() => _googleAuthError = 'Sign-in cancelled.');
      } else {
        logger.success('Google Sign-in successful for ${account.email}.');
        if(mounted) setState(() => _googleAuthError = null);
      }
    } catch (error, stackTrace) {
      logger.error('Google Sign-In error.', errorObject: error, stackTrace: stackTrace);
      if(mounted) setState(() => _googleAuthError = 'Failed to sign in. Check logs.');
    } finally {
      if(mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleSignOut() async {
    logger.info("SettingsScreen: Initiating Google Sign-Out for ${_currentUser?.email}...");
    await _googleSignIn.disconnect();
    if(mounted) setState(() {});
  }

  Future<void> _storeTokens(GoogleSignInAccount account) async {
    await _secureStorage.write(key: 'user_email', value: account.email);
    logger.info("Stored user email: ${account.email}");
  }

  Future<void> _clearTokens() async {
    await _secureStorage.delete(key: 'user_email');
    logger.info("Cleared stored user email.");
  }

  bool get _canProcess => _currentUser != null && _sheetUrlController.text.isNotEmpty && !_isProcessing;

  void _simulateSms(String type) {
    if (!_canProcess) {
      logger.warning("Simulate SMS: Prerequisites not met (User: ${_currentUser?.email}, SheetURL: ${_sheetUrlController.text}, Processing: $_isProcessing)");
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Prerequisites not met for simulation.'), backgroundColor: Colors.orange));
      return;
    }
    logger.info("Simulating $type SMS...");
    String smsBody;
    DateTime simDate = (_selectedStartDate ?? DateTime.now().subtract(const Duration(days:1)));
    String dateStr = DateFormat('MM/dd/yyyy').format(simDate);
    String mpesaDateStr = DateFormat('dd/MM/yyyy').format(simDate);

    switch (type) {
      case 'Zelle': smsBody = "Zelle: You received \$20.00 from John Doe on $dateStr. Memo: 784293."; break;
      case 'Venmo': smsBody = "Venmo: Mary Kamau paid you \$20.00 – \"918245\" on $dateStr."; break;
      case 'CashApp': smsBody = "Cash App: You received \$20.00 from Carlos Diaz on $dateStr. Note: 675312."; break;
      case 'MPesa': smsBody = "M-PESA: Confirmed. You have received Ksh 2,500 from Jane Mwangi on $mpesaDateStr at 10:45 AM. Acc. No: 918245."; break;
      default: logger.warning("Unknown SMS type for simulation: $type"); return;
    }
    _smsService.simulateSmsReceive(smsBody, "SimulatedSMS");
  }

  void _fetchEmails() async {
    if (!_canProcess) {
      logger.warning("Fetch Emails: Prerequisites not met.");
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Prerequisites not met for fetching emails.'), backgroundColor: Colors.orange));
      return;
    }
    logger.info("SettingsScreen: Initiating email fetch...");
    if(mounted) setState(() => _isProcessing = true);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fetching emails (Zelle, Venmo, CashApp)...')));
    await _emailService.fetchAndParseEmails();

    Future.delayed(const Duration(seconds: 3), () {
        if (mounted && _isProcessing) {
            bool newEmailContributionProcessedSinceFetch = _parsedContributions.any((c) => c.source.startsWith("Email") && c.date.isAfter(DateTime.now().subtract(const Duration(seconds:10))));
            if(!newEmailContributionProcessedSinceFetch) {
              logger.warning("Email fetch: Processing flag still true after timeout and no new email contributions. This might indicate no parsable emails found or an issue in callback chain for this fetch operation.");
              // Consider if _isProcessing should be reset here or if EmailService should guarantee a callback or return value.
              // For now, let's assume if no new emails are processed by callback, the operation has effectively completed or stalled.
              // setState(() => _isProcessing = false); // Be cautious with this, might hide actual processing
            }
        }
    });
  }

  void _simulateEmail(String type) {
     if (!_canProcess) {
      logger.warning("Simulate Email: Prerequisites not met.");
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Prerequisites not met for simulation.'), backgroundColor: Colors.orange));
      return;
    }
    logger.info("Simulating $type Email...");
    String subject, body;
    DateTime simDate = (_selectedStartDate ?? DateTime.now().subtract(const Duration(days:1)));
    String dateStr = DateFormat('MMMM d, yyyy').format(simDate);

    switch(type) {
      case 'Zelle':
        subject = "You’ve received money from John Doe";
        body = "Hi Leon,\n\nJohn Doe has sent you \$20.00 with Zelle® on $dateStr.\nMemo: 784293\n\nFunds are being deposited into your account ending in 1234.\n\nThanks,  \nYour Bank";
        break;
      case 'Venmo':
        subject = "Mary Kamau sent you \$20.00";
        body = "Hi Leon,\n\nMary Kamau just sent you \$20.00 on Venmo.\nNote: 918245\n\nView Transaction → [venmo.com]\n\nThanks for using Venmo!";
        break;
      case 'CashApp':
        subject = "Payment Received - \$20.00 from Carlos Diaz";
        body = "Hi Leon,\n\nYou’ve received \$20.00 from Carlos Diaz on $dateStr.\nCashtag: \$carlosd  \nNote: 675312\n\nLog in to Cash App to view full details.\n\n- Cash App Team";
        break;
      default: logger.warning("Unknown Email type for simulation: $type"); return;
    }

    _emailService.simulateEmailParse(
      subject: subject, bodyContent: body, fromAddress: "payments@example.com",
      emailDate: simDate, type: type
    );
  }

  @override
  void dispose() {
    logger.info("SettingsScreen: Disposing.");
    _sheetUrlController.dispose();
    super.dispose();
  }

  Widget _buildSimulateSmsButton(String type) {
    return ElevatedButton(
      onPressed: _canProcess ? () => _simulateSms(type) : null,
      child: Text('Simulate $type SMS'),
    );
  }

  Widget _buildSimulateEmailButton(String type) {
    return ElevatedButton(
      onPressed: _canProcess ? () => _simulateEmail(type) : null,
      child: Text('Simulate $type Email'),
    );
  }

  Widget _buildDateFilterSection() {
    final DateFormat displayFormat = DateFormat('MMM d, yyyy');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Monitoring Date Range:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            Expanded(child: Column(children: [
              TextButton(onPressed: () => _selectDate(context, true), child: Text(_selectedStartDate == null ? 'Set Start Date' : 'Start: ${displayFormat.format(_selectedStartDate!)}')),
              if (_selectedStartDate != null) IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () async {
                logger.info("Clearing start date.");
                setState(() => _selectedStartDate = null);
                final prefs = await SharedPreferences.getInstance(); await prefs.remove(_startDateKey); _updateServicesWithDateRange();
              })
            ])),
            Expanded(child: Column(children: [
              TextButton(onPressed: () => _selectDate(context, false), child: Text(_selectedEndDate == null ? 'Set End Date' : 'End: ${displayFormat.format(_selectedEndDate!)}')),
              if (_selectedEndDate != null) IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () async {
                logger.info("Clearing end date.");
                setState(() => _selectedEndDate = null);
                final prefs = await SharedPreferences.getInstance(); await prefs.remove(_endDateKey); _updateServicesWithDateRange();
              })
            ])),
          ],
        ),
        const SizedBox(height: 8),
        if (_selectedStartDate == null && _selectedEndDate == null)
            const Center(child: Text("No date filter applied. Processing all found items.", style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey))),
      ],
    );
  }

  Widget _buildSmsPermissionSection() {
    if (_smsPermissionPermanentlyDenied) {
      return Card(
        color: Colors.yellow[100],
        margin: const EdgeInsets.symmetric(vertical: 8.0),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.orange),
              const SizedBox(width: 10),
              const Expanded(child: Text("SMS permission permanently denied. Please enable it in app settings to process SMS.", style: TextStyle(fontSize: 13))),
              TextButton(onPressed: () => openAppSettings(), child: const Text("Settings")),
            ],
          ),
        ),
      );
    }
    // Could add a button to request permission if it's just denied but not permanently
    // else if (!_smsService._hasPermissions) { // Need a way to check current permission status from service
    //   return ElevatedButton(onPressed: () async {
    //     bool granted = await _smsService.checkAndRequestPermissions();
    //     if (granted) _initializeSmsService(); // Re-initialize if granted
    //     else _handleSmsPermissionDenied();
    //   }, child: Text("Grant SMS Permission"));
    // }
    return const SizedBox.shrink(); // No special UI if permission is granted or not yet checked/denied
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Setup & Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.article_outlined),
            tooltip: 'View Logs',
            onPressed: () {
              logger.info("Navigating to LogsScreen.");
              Navigator.push(context, MaterialPageRoute(builder: (context) => const LogsScreen()));
            },
          ),
          IconButton(
            icon: const Icon(Icons.table_chart_outlined),
            tooltip: 'View Sheet Data',
            onPressed: (_currentUser == null || _sheetUrlController.text.isEmpty)
              ? null
              : () {
                  logger.info("Navigating to SheetDataScreen.");
                  Navigator.push(context, MaterialPageRoute(builder: (context) => SheetDataScreen(googleSheetsService: _googleSheetsService)));
                },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Google Account:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            if (_isLoading) const Center(child: CircularProgressIndicator()),
            if (!_isLoading && _currentUser != null)
              ListTile(
                leading: GoogleUserCircleAvatar(identity: _currentUser!),
                title: Text(_currentUser!.displayName ?? ''),
                subtitle: Text(_currentUser!.email),
                trailing: TextButton(onPressed: _handleSignOut, child: const Text('Sign Out')),
              ),
            if (!_isLoading && _currentUser == null)
              Center(child: ElevatedButton(onPressed: _handleSignIn, child: const Text('Sign in with Google'))),
            if (_googleAuthError != null) Text(_googleAuthError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 24),

            _buildSmsPermissionSection(), // SMS Permission Helper

            const Text('Google Sheet URL:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            TextField(controller: _sheetUrlController, decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'https://docs.google.com/...')),
            const SizedBox(height: 16),
            Center(child: ElevatedButton(onPressed: _saveSheetUrl, child: const Text('Save Sheet URL'))),
            const Divider(height: 30),

            _buildDateFilterSection(),
            const Divider(height: 30),

            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Data Processing:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              if (_isProcessing) const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.0)),
            ]),
            const SizedBox(height: 8),

            const Text('SMS Testing:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
            Wrap(spacing: 8.0, runSpacing: 4.0, alignment: WrapAlignment.center, children: [
              _buildSimulateSmsButton('Zelle'), _buildSimulateSmsButton('Venmo'),
              _buildSimulateSmsButton('CashApp'), _buildSimulateSmsButton('MPesa'),
            ]),
            if (!_canProcess && _currentUser != null && _sheetUrlController.text.isNotEmpty)
                 Padding(padding: const EdgeInsets.only(top:4.0), child: Center(child: Text("Processing...", style: TextStyle(color: Colors.grey[600])))),
            if (_currentUser == null || _sheetUrlController.text.isEmpty)
                 Padding(padding: const EdgeInsets.only(top:4.0), child: Center(child: Text(_currentUser == null ? "Sign in to enable." : "Set Sheet URL to enable.", style: TextStyle(color: Colors.grey[600])))),
            const SizedBox(height: 16),

            const Text('Email Testing:', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
            Center(child: Wrap(spacing: 8.0, runSpacing: 4.0, alignment: WrapAlignment.center, children: [
              ElevatedButton(onPressed: _canProcess ? _fetchEmails : null, child: const Text('Fetch All Parsable Emails')),
              _buildSimulateEmailButton('Zelle'), _buildSimulateEmailButton('Venmo'), _buildSimulateEmailButton('CashApp'),
            ])),
            if (!_canProcess && _currentUser != null && _sheetUrlController.text.isNotEmpty)
                 Padding(padding: const EdgeInsets.only(top:4.0), child: Center(child: Text("Processing...", style: TextStyle(color: Colors.grey[600])))),
            if (_currentUser == null || _sheetUrlController.text.isEmpty)
                 Padding(padding: const EdgeInsets.only(top:4.0), child: Center(child: Text(_currentUser == null ? "Sign in to enable." : "Set Sheet URL to enable.", style: TextStyle(color: Colors.grey[600])))),
            const SizedBox(height: 20),

            if (_parsedContributions.isNotEmpty) ...[
              const Text('Recently Processed (Filtered & Unique):', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ListView.builder(
                shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
                itemCount: _parsedContributions.length,
                itemBuilder: (context, index) {
                  final contrib = _parsedContributions.reversed.toList()[index];
                  return ListTile(
                    title: Text("${contrib.senderName} - ${contrib.currency} ${contrib.amount.toStringAsFixed(2)}"),
                    subtitle: Text("ID: ${contrib.memberId} on ${DateFormat('MM/dd/yyyy').format(contrib.date)} | Source: ${contrib.source}"),
                  );
                },
              ),
            ],
            const SizedBox(height: 24),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8.0),
              child: Text('Note: Ensure APIs are enabled, OAuth configured, permissions granted, and Sheet accessible.', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic), textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}
