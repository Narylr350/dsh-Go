import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/companion_session_peer.dart';

void main() {
  test('watch cuts a snapshot at creation and buffers later journal events after it', () async {
    final peer = CompanionSessionPeer(DshConnection(Uri.parse('http://127.0.0.1')));
    addTearDown(peer.closeAll);
    peer.journal('room', 'turn/start', {'turn': 1});
    final frames = peer.watch('room');
    peer.journal('room', 'step/start', {'turn': 1, 'step': 1});

    final events = await frames.take(2).toList();
    final snapshot = events.first as SessionSnapshotEvent;
    expect(snapshot.cursor, 0);
    final first = snapshot.events.single as TurnStartedEvent;
    expect((first.seq, first.turn), (0, 1));
    final next = events.last as StepStartedEvent;
    expect((next.seq, next.turn, next.step), (1, 1, 1));
  });
}
