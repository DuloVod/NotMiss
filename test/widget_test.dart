import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notmiss/main.dart';
import 'package:notmiss/services/settings_store.dart';

void main() {
  group('NotMissApp', () {
    testWidgets('shows error screen when destination is null',
        (WidgetTester tester) async {
      await tester.pumpWidget(NotMissApp(
        apiKey: '',
        settings: SettingsStore(),
        destination: null,
        loadError: 'Test error',
      ));

      // Error screen should appear with the message
      expect(find.text('Помилка запуску'), findsOneWidget);
      expect(find.text('Test error'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('shows error screen when destination is null with default message',
        (WidgetTester tester) async {
      await tester.pumpWidget(NotMissApp(
        apiKey: '',
        settings: SettingsStore(),
        destination: null,
      ));

      expect(find.text('Помилка запуску'), findsOneWidget);
      expect(find.text('Дані парку не завантажились.'), findsOneWidget);
    });
  });
}
