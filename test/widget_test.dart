import 'package:flutter_test/flutter_test.dart';
import 'package:ekopi_kalteng_flutter/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const EkopiApp());
    expect(find.byType(EkopiApp), findsOneWidget);
  });
}
