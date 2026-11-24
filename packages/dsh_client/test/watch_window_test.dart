// The initial `session/follow` window: the same options as the official web
// client, so the Host cuts at a turn start (the oldest loaded turn keeps its
// `turn/start`) instead of at the 50th message (its default cap).

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';
import 'support/history_fill_harness.dart' show historyFrame, historySnapshot;

const _fastMux = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]);

void main() {
  test('the default window: at least 50 messages and two turns, capped at 500', () {
    const options = WatchOptions();
    expect(options.maxMessages, 500);
    expect(options.turnWindow?.toJson(), {'minMessages': 50, 'minTurns': 2});
  });

  test('watch sends maxMessages 500 with the turn window by default', () async {
    final host = await FakeDsh.start();
    addTearDown(host.close);
    final opened = Completer<Map<String, Object?>>();
    host.onOpen = (socket, streamId, endpoint, payload) {
      if (endpoint == 'session/follow' && !opened.isCompleted) opened.complete(payload);
    };
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, muxOptions: _fastMux);
    addTearDown(client.close);
    final sub = client.watch('session-1').listen((_) {}, onError: (_) {});
    addTearDown(sub.cancel);

    final payload = await opened.future.timeout(const Duration(seconds: 5));
    final request = (payload['args']! as Map)['request']! as Map;
    expect(request['maxMessages'], 500);
    expect(request['turnWindow'], {'minMessages': 50, 'minTurns': 2});
  });
  for (final resume in [false, true]) {
    test('replacement watch fills only an already-held transcript: $resume', () async {
      final host = await FakeDsh.start();
      addTearDown(host.close);
      final pages = <int>[];
      host.handlers['session/page'] = (args) {
        final request = args['request']! as Map;
        pages.add(request['beforeSeq']! as int);
        return {
          'ok': true,
          'value': {'records': [historyFrame(1), historyFrame(2)], 'hasMore': false},
        };
      };
      host.onOpen = (socket, streamId, endpoint, payload) {
        if (endpoint != 'session/follow') return;
        socket.item(streamId, historySnapshot(3, [historyFrame(3)]));
      };
      final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, muxOptions: _fastMux);
      addTearDown(client.close);
      final transcript = ChatTranscript()..apply(parseFollowFrame('s', historyFrame(0)));
      final options = WatchOptions(
        assistantStream: false,
        includeSyncEvents: true,
        resumeAfterSeq: resume ? transcript.cursor : null,
      );
      final snapshot = await client.watch('s', options: options)
          .where((event) => event is SessionSnapshotEvent)
          .cast<SessionSnapshotEvent>()
          .first
          .timeout(const Duration(seconds: 5));
      transcript.apply(snapshot);
      expect(snapshot.isResync, resume);
      expect(pages, resume ? [3] : isEmpty);
      expect(transcript.events.map((e) => e.seq), resume ? [0, 1, 2, 3] : [3]);
    });
  }
}
