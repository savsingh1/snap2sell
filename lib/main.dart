import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_navigator.dart';
import 'app_theme.dart';
import 'providers/app_state.dart';
import 'screens/welcome_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState()..init(),
      child: const Snap2SellApp(),
    ),
  );
}

class Snap2SellApp extends StatelessWidget {
  const Snap2SellApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Snap2Sell',
      debugShowCheckedModeBanner: false,
      theme: buildSnapTheme(),
      navigatorKey: appNavigatorKey,
      home: const WelcomeScreen(),
    );
  }
}
