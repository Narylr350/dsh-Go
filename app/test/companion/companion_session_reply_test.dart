import 'package:dsh_app/companion/companion_session_reply.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ChatTranscript transcript;
  late int seq;

  void log(String type, Map<String, Object?> data) {
    transcript.apply(SessionLogEvent.fromJson({'type': type, 'seq': seq++, 'time': 0, 'data': data}));
  }

  int user(String source, [String? id]) {
    final echo = seq;
    log('user/message', {
      'role': 'user',
      'id': 'input-$echo',
      'source': {'kind': source, 'rpcId': ?id},
      'content': [
        {'type': 'text', 'text': 'same input'},
      ],
    });
    return echo;
  }

  void claim() => log('agent/inbox/spliced', {'target': 'next-step', 'start': 0, 'removedCount': 1, 'inserted': []});
  void step(int n) => log('step/start', {'turn': 1, 'step': n});
  void end(int n) => log('step/end', {'turn': 1, 'step': n});
  void answer(int n, String text) => log('assistant/message', {
    'turn': 1,
    'step': n,
    'message': {
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': text},
      ],
    },
  });
  void read(CompanionSessionReply reply) => reply.observe(transcript.eventsFrom(reply.nextSeq));

  setUp(() {
    transcript = ChatTranscript();
    seq = 0;
    log('turn/start', {'turn': 1});
  });

  for (final replacement in ['schedule', 'goal', 'user']) {
    test('a claimed $replacement owns its step, also when the first watch is a snapshot', () {
      claim();
      step(1);
      final first = user('user', 'room');
      final live = CompanionSessionReply(0, first);
      read(live);
      answer(1, 'original');
      end(1);
      claim();
      step(2);
      final second = user(replacement, 'other');
      read(live);
      expect(live.ownsLatest, isFalse);
      answer(2, 'replacement');
      end(2);
      for (final reply in [live, CompanionSessionReply(0, first)]) {
        read(reply);
        expect(reply.text(transcript.items), 'original');
        expect(reply.ownsLatest, isFalse);
      }
      if (replacement == 'user') {
        final other = CompanionSessionReply(0, second);
        read(other);
        expect(other.text(transcript.items), 'replacement');
        expect(other.ownsLatest, isTrue);
      }
    });
  }

  test('an early correction preserves the late commit of the old in-flight step', () {
    final first = user('user', 'room');
    step(1);
    final second = user('user', 'other');
    answer(1, 'late original');
    end(1);
    step(2);
    answer(2, 'corrected');
    for (final (echo, text) in [(first, 'late original'), (second, 'corrected')]) {
      final reply = CompanionSessionReply(0, echo);
      read(reply);
      expect(reply.text(transcript.items), text);
    }
  });

  test('context, a helper and an ordinary next step stay with their current input', () {
    claim();
    step(1);
    final echo = user('user', 'room');
    user('runtime-context');
    answer(1, 'working');
    end(1);
    step(2);
    user('skill-catalog');
    user('subagent');
    answer(2, 'done');
    final reply = CompanionSessionReply(0, echo);
    read(reply);
    expect(reply.text(transcript.items), 'working\ndone');
    expect(reply.ownsLatest, isTrue);
  });

  test('a peer can publish a durable answer without a separate step start', () {
    final echo = user('user', 'room');
    answer(1, 'done');
    final reply = CompanionSessionReply(0, echo);
    read(reply);
    expect(reply.text(transcript.items), 'done');
  });
  test('a later echo does not transfer an in-flight failure or tool to the new person', () {
    final first = user('user', 'first');
    step(1);
    final second = user('user', 'second');
    log('tool/call', {'turn': 1, 'step': 1, 'callId': 'read', 'name': 'read_note', 'arguments': '{}'});
    end(1);
    final previous = CompanionSessionReply(0, first);
    final next = CompanionSessionReply(0, second);
    read(previous);
    read(next);
    expect(previous.ownsLatest, isFalse);
    expect(previous.ownsLastStep, isTrue);
    expect(previous.toolDispatched, isTrue);
    expect(next.ownsLatest, isTrue);
    expect(next.ownsLastStep, isFalse);
    expect(next.toolDispatched, isFalse);
  });
}
