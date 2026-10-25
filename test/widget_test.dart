import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lancom/main.dart';

void main() {
  testWidgets('shows the setup screen on launch', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const LanComApp());
    await tester.pumpAndSettle();

    expect(find.text('Share files locally'), findsOneWidget);
    expect(find.text('What should others see you as?'), findsOneWidget);
    expect(find.text('Let me in'), findsOneWidget);
  });
}
