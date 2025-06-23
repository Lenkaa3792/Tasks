import 'package:flutter/material.dart';
import 'package:truefam_contribution_tracker/settings_screen.dart'; // Import the new screen

void main() {
  // Ensure Flutter bindings are initialized, especially if you add async operations before runApp
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TrueFam Contribution Tracker',
      theme: ThemeData(
        primarySwatch: Colors.blue, // Consider using colorScheme for more modern theming
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent),
        useMaterial3: true,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const SettingsScreen(), // Set SettingsScreen as the home
    );
  }
}

// MyHomePage is no longer needed here as the entry point, but can be kept for other purposes
// class MyHomePage extends StatefulWidget {
//   const MyHomePage({super.key, required this.title});
//
//   final String title;
//
//   @override
//   State<MyHomePage> createState() => _MyHomePageState();
// }
//
// class _MyHomePageState extends State<MyHomePage> {
//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(
//         title: Text(widget.title),
//       ),
//       body: const Center(
//         child: Text(
//           'Welcome to TrueFam Contribution Tracker!',
//         ),
//       ),
//     );
//   }
// }
