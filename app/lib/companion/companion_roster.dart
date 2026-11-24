// Several companions on one phone (the pack store keeps the others on a
// shelf). Who she is goes with her: the name the person gave her and the
// persona they wrote are kept per character and put back when she returns.
// How she calls the person is about the person, so it stays as it is; so do
// memory and reminders, which are about the person too.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'companion_state.dart';

const _identityPrefix = 'companion_identity_v1:';

/// Whose name and persona the settings hold right now.
const _ownerKey = 'companion_identity_owner';

/// Written before changing the shared settings. An empty target forgets their
/// current owner; otherwise the target's existing shelf record is restored.
const _pendingOwnerKey = 'companion_identity_pending_v1';

/// One handoff at a time: a second switch waits for the first to finish.
Future<bool>? _queue;

Future<bool> _enqueue(Future<bool> Function() step) {
  final previous = _queue ?? Future<bool>.value(false);
  late final Future<bool> next;
  next = previous.then((_) => _safely(step)).whenComplete(() {
    // Only the last handoff releases the queue and its scheduling zone.
    if (identical(_queue, next)) _queue = null;
  });
  return _queue = next;
}

/// Makes the name and persona settings [key]'s: whoever they belonged to
/// keeps hers for when she's back, and [key] gets what she had (none yet:
/// her pack's name and the default persona). The first character ever seen
/// simply owns what is there. True when they changed hands.
///
/// It runs wherever she arrives (a switch here, a Workshop install made
/// elsewhere, a restart after one was cut short), so the settings always
/// follow whoever is in the room.
Future<bool> companionAdoptIdentity(WidgetRef ref, String key) => _enqueue(() => _adopt(ref, key));

/// Settings that can't be read or written (or a room already gone) leave
/// things as they are; the next arrival tries again.
Future<bool> _safely(Future<bool> Function() step) async {
  try {
    return await step();
  } on Object {
    return false;
  }
}

Future<SharedPreferences> _identityPreferences(WidgetRef ref) async {
  ref.read(companionNameProvider.notifier);
  await ref.read(companionPersonaProvider.notifier).ready;
  return SharedPreferences.getInstance();
}

Map<Object?, Object?>? _saved(SharedPreferences prefs, String key) {
  try {
    final decoded = jsonDecode(prefs.getString('$_identityPrefix$key') ?? 'null');
    return decoded is Map ? decoded : null;
  } on FormatException {
    return null;
  }
}

typedef CompanionRequestIdentity = ({String? name, String custom, String callMe});

/// Read the profile at dispatch, including when a room already shows the
/// next pack and an earlier preference write is still in flight.
Future<CompanionRequestIdentity Function(String?)> companionRequestIdentityReader(Ref ref) async {
  ref.read(companionNameProvider.notifier);
  await ref.read(companionPersonaProvider.notifier).ready;
  final prefs = await SharedPreferences.getInstance();
  return (key) {
    final persona = ref.read(companionPersonaProvider);
    final owner = prefs.getString(_ownerKey), pending = prefs.getString(_pendingOwnerKey);
    if (owner != key || (pending != null && pending != key)) {
      final saved = key == null ? null : _saved(prefs, key);
      if (owner != null || pending != null || saved != null) {
        final name = saved?['name'], custom = saved?['custom'];
        return (name: name is String ? name : null, custom: custom is String ? custom : '', callMe: persona.callMe);
      }
    }
    // The active owner (or the first legacy pack) gets its live edits.
    return (name: ref.read(companionNameProvider), custom: persona.custom, callMe: persona.callMe);
  };
}

/// The owner changes last. If the process stopped before then, replay the
/// target settings without saving the partially restored values over anyone.
Future<bool> _finishPending(WidgetRef ref, SharedPreferences prefs) async {
  final target = prefs.getString(_pendingOwnerKey);
  if (target == null) return false;
  final owner = prefs.getString(_ownerKey);
  if (target.isEmpty ? owner != null : owner != target) {
    if (target.isEmpty) await prefs.remove('$_identityPrefix$owner');
    final saved = target.isEmpty ? null : _saved(prefs, target);
    final name = saved?['name'], custom = saved?['custom'];
    final callMe = ref.read(companionPersonaProvider).callMe;
    await ref.read(companionNameProvider.notifier).set(name is String ? name : null);
    await ref
        .read(companionPersonaProvider.notifier)
        .set(CompanionPersonaSettings(custom: custom is String ? custom : '', callMe: callMe));
    if (target.isEmpty) {
      await prefs.remove(_ownerKey);
    } else {
      await prefs.setString(_ownerKey, target);
    }
  }
  await prefs.remove(_pendingOwnerKey);
  return true;
}

Future<bool> _adopt(WidgetRef ref, String key) async {
  final prefs = await _identityPreferences(ref);
  final recovered = await _finishPending(ref, prefs);
  final owner = prefs.getString(_ownerKey);
  if (owner == key) return recovered;
  if (owner == null && _saved(prefs, key) == null) {
    // The first arrival on an older installation inherits its existing settings.
    await prefs.setString(_ownerKey, key);
    return recovered;
  }
  if (owner != null) {
    await prefs.setString(
      '$_identityPrefix$owner',
      jsonEncode({'name': ref.read(companionNameProvider), 'custom': ref.read(companionPersonaProvider).custom}),
    );
  }
  await prefs.setString(_pendingOwnerKey, key);
  return _finishPending(ref, prefs);
}

/// [key] left the phone: what was kept for her goes, and if the settings were
/// hers they go back to the defaults (how she calls the person stays).
Future<void> companionForgetIdentity(WidgetRef ref, String key) => _enqueue(() => _forget(ref, key));

Future<bool> _forget(WidgetRef ref, String key) async {
  final prefs = await _identityPreferences(ref);
  await _finishPending(ref, prefs);
  if (prefs.getString(_ownerKey) != key) {
    await prefs.remove('$_identityPrefix$key');
    return false;
  }
  await prefs.setString(_pendingOwnerKey, '');
  return _finishPending(ref, prefs);
}
