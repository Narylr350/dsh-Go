import 'package:dsh_client/dsh_client.dart';

/// Assigns the steps of a shared Host turn to this room's particular user echo.
class CompanionSessionReply {
  CompanionSessionReply(this.nextSeq, this.echoSeq);

  final int echoSeq;
  int nextSeq;
  final _steps = <String, bool>{};
  String? _step;
  String? _lastStep;
  bool? _ours;
  bool _claimed = false;
  bool toolDispatched = false;

  bool get ownsLatest => _ours == true;
  bool get ownsLastStep => _steps[_lastStep] ?? ownsLatest;

  void observe(Iterable<SessionLogEvent> events, {int? endSeq}) {
    for (final event in events) {
      if (endSeq != null && event.seq > endSeq) break;
      nextSeq = event.seq + 1;
      switch (event) {
        case InboxSplicedEvent(removedCount: > 0, canceled: false):
          // The real Host claims its inbox, opens the step, then writes its inputs.
          _claimed = true;
        case StepStartedEvent():
          final key = 'm${event.turn}.${event.step}';
          _step = _lastStep = key;
          _steps[key] = ownsLatest;
        case AssistantMessageEvent():
          // Peers may send the durable answer without a separate step/start.
          final key = 'm${event.turn}.${event.step}';
          if (!_steps.containsKey(key)) {
            _lastStep = key;
            _steps[key] = ownsLatest;
          }
        case ToolCallEvent():
          if (event.seq > echoSeq && (_steps['m${event.turn}.${event.step}'] ?? ownsLatest)) toolDispatched = true;
        case StepEndedEvent():
          _step = null;
          _claimed = false;
        case UserMessageEvent()
            when event.isHumanPrompt || event.message.source.kind == 'schedule' || event.message.source.kind == 'goal':
          final ours = event.seq == echoSeq;
          // An echo outside a claim can arrive while an older step is still speaking.
          // Its successor inherits this input. The in-flight step keeps its owner.
          if (_step case final key? when _claimed || _ours == null) {
            _steps[key] = ours;
          }
          _ours = ours;
        default:
          break;
      }
    }
  }

  String text(List<ChatItem> items) {
    final parts = <String>[];
    for (final item in items.reversed) {
      if (item is UserChatItem && item.seq <= echoSeq) break;
      if (item is AssistantChatItem && _steps[item.rowKey] == true && item.text.isNotEmpty) {
        parts.add(item.text);
      }
    }
    return parts.reversed.join('\n');
  }
}
