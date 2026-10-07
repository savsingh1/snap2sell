import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snap2sell/main.dart';
import 'package:snap2sell/providers/app_state.dart';

void main() {
  testWidgets('App boots to the welcome screen', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState()..init(),
        child: const Snap2SellApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Snap it. Sell it. Done.'), findsOneWidget);
    expect(find.text('Skip to dashboard'), findsOneWidget);
  });

  testWidgets('Skip to dashboard opens the home screen',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState()..init(),
        child: const Snap2SellApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Skip to dashboard'));
    await tester.pumpAndSettle();

    expect(find.text('Snap an Item'), findsOneWidget);
  });
}
