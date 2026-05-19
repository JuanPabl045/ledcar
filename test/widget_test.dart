import 'package:flutter_test/flutter_test.dart';
import 'package:ledcar/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const LedCarApp());
    expect(find.text('LedCar'), findsOneWidget);
  });
}
