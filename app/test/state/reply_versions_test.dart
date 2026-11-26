import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/reply_versions_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../workspace/support.dart';

class _SwitchHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;

  void set(HostRef host) => state = host;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const local = HostRef.local;
  ProviderContainer start() {
    final container = ProviderContainer(overrides: [activeHostProvider.overrideWith(_SwitchHost.new)]);
    addTearDown(container.dispose);
    return container;
  }

  Future<void> fork(
    ReplyVersionsController versions,
    String parent,
    int parentSeq,
    String child, {
    int? childSeq,
    bool edited = false,
    HostRef host = local,
  }) => versions.recordFork(
    host,
    parentSessionId: parent,
    parentPromptSeq: parentSeq,
    childSessionId: child,
    childPromptSeq: childSeq,
    edited: edited,
  );

  test('the source and real resend seq anchor each turn independently', () async {
    final container = start();
    final versions = container.read(replyVersionsProvider.notifier);
    await fork(versions, 'a', 10, 'b', childSeq: 14);
    await fork(versions, 'b', 40, 'c', childSeq: 46);
    await fork(versions, 'c', 14, 'd', childSeq: 17);
    await fork(versions, 'b', 40, 'e', childSeq: 39, edited: true);

    final index = container.read(replyVersionsProvider).requireValue;
    const firstTurn = [
      (sessionId: 'a', promptSeq: 10),
      (sessionId: 'b', promptSeq: 14),
      (sessionId: 'd', promptSeq: 17),
    ];
    const secondTurn = [
      (sessionId: 'b', promptSeq: 40),
      (sessionId: 'c', promptSeq: 46),
      (sessionId: 'e', promptSeq: 39),
    ];
    final inherited = index.selectionFor('c', 14)!;
    expect(inherited.versions, firstTurn);
    expect(inherited.index, 1);
    expect(inherited.hasEdits, isFalse);
    expect(index.selectionFor('d', 17)?.index, 2);
    expect(index.selectionFor('c', 46)?.versions, secondTurn);
    expect(index.selectionFor('c', 46)?.index, 1);
    expect(index.selectionFor('c', 46)?.hasEdits, isTrue);
    expect(index.selectionFor('e', 39)?.index, 2);
    expect(index.selectionFor('a', 40), isNull);
    expect(index.selectionFor('d', 46), isNull);
    expect(index.sessionIdsFor('c'), {'a', 'b', 'c', 'd', 'e'});
  });

  test('a missing author is reachable from an inheriting branch without exposing missing sessions', () async {
    final container = start();
    final versions = container.read(replyVersionsProvider.notifier);
    await fork(versions, 'a', 10, 'b', childSeq: 14);
    await fork(versions, 'b', 40, 'c', childSeq: 46);
    await fork(versions, 'a', 10, 'd', childSeq: 17);

    final before = container.read(replyVersionsProvider).requireValue;
    final visible = before.selectionFor('a', 10, availableSessionIds: {'a', 'c'})!;
    expect(visible.versions, [(sessionId: 'a', promptSeq: 10), (sessionId: 'c', promptSeq: 14)]);
    expect(visible.index, 0);

    const afterRemoval = {'a', 'c', 'd'};
    final inherited = before.selectionFor('c', 14, availableSessionIds: afterRemoval)!;
    expect(inherited.index, 1);
    expect(inherited.versions.map((version) => version.sessionId), ['a', 'c', 'd']);
    expect(before.selectionFor('c', 46, availableSessionIds: afterRemoval), isNull);
  });

  test('an earlier arrow switches back to the most recently opened continuation of its version', () async {
    final container = start();
    final versions = container.read(replyVersionsProvider.notifier);
    await fork(versions, 'a', 10, 'b', childSeq: 14);
    await fork(versions, 'b', 40, 'c', childSeq: 46);
    await fork(versions, 'c', 70, 'pending');
    await versions.select(local, 'c');
    await versions.select(local, 'pending');
    await versions.select(local, 'a');
    final index = container.read(replyVersionsProvider).requireValue;
    final selected = index.selectionFor('a', 10)!;
    expect(selected.versions, [(sessionId: 'a', promptSeq: 10), (sessionId: 'c', promptSeq: 14)]);
    expect(selected.index, 0);
    expect(index.selectionFor('c', 14)?.index, 1);
    expect(index.selectionFor('a', 10, availableSessionIds: {'a', 'b'})?.versions.last.sessionId, 'b');
  });

  test('host keys isolate identical session ids and ignore relay display names', () async {
    final container = start();
    final hosts = container.read(activeHostProvider.notifier) as _SwitchHost;
    final versions = container.read(replyVersionsProvider.notifier);
    const ssh = HostRef.ssh('pc');
    const relay = HostRef.relay('pc', name: 'before');
    await fork(versions, 'a', 10, 'b', childSeq: 14);
    hosts.set(ssh);
    final empty = await container.read(replyVersionsProvider.future);
    expect(empty.host, ssh);
    expect(empty.selectionFor('a', 10), isNull);
    await fork(versions, 'a', 10, 'r', childSeq: 14, host: relay);
    expect(container.read(replyVersionsProvider).requireValue.host, ssh);
    hosts.set(const HostRef.relay('pc', name: 'after'));
    final remote = await container.read(replyVersionsProvider.future);
    expect(remote.selectionFor('a', 10)?.versions.last.sessionId, 'r');
    hosts.set(local);
    final restored = await container.read(replyVersionsProvider.future);
    expect(restored.selectionFor('a', 10)?.versions.last.sessionId, 'b');
  });

  test('drawer represents one real row, waits for the first prompt and restores the last selection', () async {
    final host = FakeWorkspaceHost();
    final time = DateTime.utc(2026, 11, 27);
    host.seedSession('a', 'First', time);
    host.seedSession('ordinary', 'Independent', time.add(const Duration(seconds: 1)));
    host.seedSession('b', 'Edited', time.add(const Duration(seconds: 2)));
    final connection = workspaceHost(host);
    addTearDown(connection.client.close);
    await connection.client.mux.start();

    ProviderContainer open() {
      final container = ProviderContainer(
        overrides: [
          activeConnectionProvider.overrideWithValue(AsyncData(connection)),
          readListIdentityProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Iterable<String> rows(ProviderContainer c) => c.read(sessionsProvider).requireValue.map((s) => s.sessionId);
    final first = open();
    final versions = first.read(replyVersionsProvider.notifier);
    await fork(versions, 'a', 10, 'b', edited: true);
    final waiting = first.read(replyVersionsProvider).requireValue;
    expect(waiting.needsPrompt('b'), isTrue);
    expect(waiting.selectionFor('a', 10), isNull);
    await first.read(sessionsProvider.future);
    expect(rows(first), ['ordinary', 'a']);

    first.read(currentSessionProvider.notifier).select('b');
    await pumpEventQueue();
    expect(rows(first), ['ordinary', 'a']);
    await versions.bindChildPrompt(local, 'b', 14);
    await versions.bindChildPrompt(local, 'b', 15); // A later human turn cannot overwrite the binding.
    expect(rows(first), ['b', 'ordinary']);
    expect(first.read(replyVersionsProvider).requireValue.needsPrompt('b'), isFalse);
    expect(first.read(replyVersionsProvider).requireValue.selectionFor('b', 14)?.hasEdits, isTrue);
    expect(first.read(replyVersionsProvider).requireValue.selectionFor('b', 15), isNull);
    expect(first.read(hostSessionsProvider).keys, unorderedEquals(['a', 'b', 'ordinary']));

    first.read(currentSessionProvider.notifier).select('a');
    await pumpEventQueue();
    expect(rows(first), ['ordinary', 'a']);
    final second = open();
    await second.read(replyVersionsProvider.future);
    await second.read(sessionsProvider.future);
    expect(rows(second), ['ordinary', 'a']);
    expect(second.read(hostSessionsProvider).keys, unorderedEquals(['a', 'b', 'ordinary']));
    expect(second.read(replyVersionsProvider).requireValue.selectionFor('b', 14)?.hasEdits, isTrue);
    second.read(currentSessionProvider);
    await pumpEventQueue();
    expect(second.read(currentSessionProvider), 'a');

    host.sessions.removeWhere((session) => session['sessionId'] == 'a');
    await second.read(sessionsProvider.notifier).refresh();
    expect(rows(second), ['b', 'ordinary']);
  });
}
