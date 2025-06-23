class Contribution {
  final String senderName;
  final double amount;
  final String memberId; // Memo
  final DateTime date;
  final String source; // SMS or Email
  final String? originalMessage; // Optional: store the original message for reference/debugging
  final String? currency; // Optional: for handling different currencies like KSh

  Contribution({
    required this.senderName,
    required this.amount,
    required this.memberId,
    required this.date,
    required this.source,
    this.originalMessage,
    this.currency = 'USD', // Default to USD
  });

  @override
  String toString() {
    return 'Contribution(senderName: $senderName, amount: $amount $currency, memberId: $memberId, date: $date, source: $source)';
  }

  // For Google Sheets, we'll likely want a method to convert this to a list of objects
  List<dynamic> toSheetRow() {
    // Format date as MM/dd/yyyy for the sheet
    String formattedDate = "${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}/${date.year}";
    return [
      senderName,
      amount, // Assuming amount is always in USD for this column as per spec
      memberId,
      formattedDate,
      source,
    ];
  }
}
