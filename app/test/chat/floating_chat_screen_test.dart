import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

void main() {
  testWidgets('floating chat keeps its conversation, sending, replies and model picker after resizing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    mockClipboard(tester);
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(900, 1600);
    addTearDown(tester.view.reset);
    const id = 'floating-current';
    final initial = ChatState(
      loading: false,
      model: testCatalog.defaultSelection,
      items: [user(1, '已有的问题'), assistant(2, '已有的回复')],
    );
    final harness = ChatHarness(session: id, states: {id: initial});
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    final chat = harness.controllers[id]!;
    expect(container.read(currentSessionProvider), id);
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextField), '小窗里的消息');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester);
    expect(chat.sent, ['小窗里的消息']);

    chat.emit(ChatState(loading: false, model: initial.model, items: [...initial.items, assistant(3, '小窗收到新回复')]));
    await pumpFrames(tester);
    expect(find.textContaining('小窗收到新回复', findRichText: true), findsOneWidget);

    await tester.tap(find.byType(TextField));
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('composer-model')));
    await pumpFrames(tester);
    await tester.tap(find.text('V41 Flash'));
    await pumpFrames(tester);
    expect(chat.models.single.model, 'deepseek-flash');
    await tester.tapAt(const Offset(10, 10));
    await pumpFrames(tester);

    tester.view.physicalSize = const Size(1440, 960);
    await pumpFrames(tester);
    expect(container.read(currentSessionProvider), id);
    expect(identical(harness.controllers[id], chat), isTrue);
    expect(harness.controllers.keys, [id]);
    expect(tester.takeException(), isNull);
  });
}
