import 'package:flutter_test/flutter_test.dart';
import 'package:ledcar/main.dart';

void main() {
  testWidgets('App shows issue text', (WidgetTester tester) async {
    await tester.pumpWidget(const LedCarApp());
    expect(find.text('Hola 12'), findsOneWidget);
  });
}
