import 'package:flutter/material.dart';
import 'services/revenuecat_service.dart';
import 'services/cache_cleaner.dart';
import 'screens/record_screen.dart';
import 'screens/processing_screen.dart';
import 'screens/feedback_screen.dart';
import 'screens/paywall_screen.dart';
import 'screens/scorecard_failed_screen.dart';
import 'models/score_response.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RevenueCatService.init();
  
  // Clean up old temp files on app start
  CacheCleaner.purgeOldFiles();
  
  runApp(const BenchMvpApp());
}

class BenchMvpApp extends StatelessWidget {
  const BenchMvpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'bench_mvp',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.transparent,
        fontFamily: 'SF Pro',
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
      ),
      initialRoute: RecordScreen.routeName,
      routes: {
        RecordScreen.routeName: (_) => const RecordScreen(),
        ProcessingScreen.routeName: (_) => const ProcessingScreen(),
        FeedbackScreen.routeName: (_) => const FeedbackScreen(),
        PaywallScreen.routeName: (_) => const PaywallScreen(),
        ScorecardFailedScreen.route: (ctx) {
          final args = ModalRoute.of(ctx)!.settings.arguments as FailureInfo;
          return ScorecardFailedScreen(failure: args);
        },
      },
    );
  }
}
