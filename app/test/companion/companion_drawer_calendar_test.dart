import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/companion/companion_drawer_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('drawer reminder dates follow local calendar days across clock changes', (tester) async {
    const marker = Key('reminder-calendar-context');
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('zh'),
        supportedLocales: L10n.supportedLocales,
        localizationsDelegates: L10n.localizationsDelegates,
        home: SizedBox(key: marker),
      ),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byKey(marker));
    final words = context.l10n;
    for (final now in [
      DateTime(2024, 2, 28, 8),
      DateTime(2026, 3, 8, 8),
      DateTime(2026, 3, 29, 8),
      DateTime(2026, 9, 27, 8),
      DateTime(2026, 10, 4, 8),
      DateTime(2026, 12, 31, 8),
    ]) {
      for (final offset in [0, 1, 2]) {
        final due = DateTime(now.year, now.month, now.day + offset, 9);
        final time = MaterialLocalizations.of(context).formatTimeOfDay(
          TimeOfDay.fromDateTime(due),
          alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
        );
        final expected = switch (offset) {
          0 => words.companionDrawerReminderToday(time),
          1 => words.companionDrawerReminderTomorrow(time),
          _ => words.companionDrawerReminderLater(words.monthDay(due)),
        };
        expect(CompanionDrawerRow.reminderText(context, due, now), expected, reason: '$now → $due');
      }
    }
  });
}
