import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const LedCarApp());
}

class LedCarApp extends StatelessWidget {
  const LedCarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LedCar',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A56DB),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
