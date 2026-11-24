// Her own words for touches and her things. The app's built-in lines were
// written for one character; anyone else should sound like herself. In order:
// the lines her pack brings (`lines` in character.json), else a set written
// once in her voice from her name and persona, else neutral defaults.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'companion_light.dart';

/// One set of lines per moment.
class CompanionLines {
  const CompanionLines(this.sets);

  /// The moments she has words for, and what each means (for the writer).
  static const moments = {
    'pat': 'being patted on the head',
    'patClose': 'being patted, once you are very close',
    'hug': 'being hugged',
    'hugClose': 'being hugged, once you are very close',
    'tease': 'being poked again and again',
    'shake': 'the phone being shaken until she is dizzy',
    'tapHead': 'a tap on the head',
    'tapFace': 'a poke on the cheek',
    'tapBody': 'a tap on the body',
    'tapTail': 'a touch on the lower body or a tail, if she has one',
    'tapLegs': 'a tap near her feet',
    'snack': 'eating a snack she was given',
    'play': 'playing with a ball she was tossed',
    'rest': 'resting on a cushion beside you',
  };

  final Map<String, List<String>> sets;

  /// The lines for [moment], or null to fall back.
  List<String>? operator [](String moment) => sets[moment];

  bool get isEmpty => sets.isEmpty;

  /// Known moments with at least one non-empty line; anything else is ignored.
  factory CompanionLines.parse(Object? json) {
    final sets = <String, List<String>>{};
    if (json is Map) {
      for (final moment in moments.keys) {
        final value = json[moment];
        final lines = [
          if (value is String) value.trim(),
          if (value is List)
            for (final line in value)
              if (line is String) line.trim(),
        ].where((line) => line.isNotEmpty).toList();
        if (lines.isNotEmpty) sets[moment] = lines;
      }
    }
    return CompanionLines(sets);
  }

  Map<String, Object?> toJson() => sets;
}

const _cachePrefix = 'companion_lines_v1:';

/// The set written for [character] under persona [fingerprint], if any.
Future<CompanionLines?> companionLinesCached(String character, String fingerprint) async {
  try {
    final raw = (await SharedPreferences.getInstance()).getString('$_cachePrefix$character');
    final json = raw == null ? null : jsonDecode(raw);
    if (json is! Map || json['fingerprint'] != fingerprint) return null;
    final lines = CompanionLines.parse(json['lines']);
    return lines.isEmpty ? null : lines;
  } on Object {
    return null;
  }
}

class _LineRequests {
  int active = 0;
  String fingerprint = '';
  Future<void> saving = Future.value();
}

final _lineRequests = <String, _LineRequests>{};

/// Resolve this character's current profile. Each character has one cache
/// slot. While overlapping reads or model requests are outstanding, only
/// the most recently requested fingerprint can populate that slot.
Future<CompanionLines?> companionLinesForProfile(
  String character,
  String fingerprint,
  Future<CompanionLines?> Function() generate,
) async {
  final requests = _lineRequests.putIfAbsent(character, _LineRequests.new);
  requests.active++;
  requests.fingerprint = fingerprint;
  bool wanted() => requests.fingerprint == fingerprint;
  try {
    final cached = await companionLinesCached(character, fingerprint);
    if (!wanted()) return null;
    if (cached != null) return cached;
    final lines = await generate();
    if (lines == null || !wanted()) return null;
    requests.saving = requests.saving.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        if (wanted()) {
          await prefs.setString(
            '$_cachePrefix$character',
            jsonEncode({'fingerprint': fingerprint, 'lines': lines.toJson()}),
          );
        }
      } on Object {
        // The current page can use the words even if storage is unavailable.
      }
    });
    await requests.saving;
    return wanted() ? lines : null;
  } finally {
    if (--requests.active == 0) _lineRequests.remove(character);
  }
}

/// Generate the words for an uncached profile.
Future<CompanionLines?> companionGenerateLines({
  required http.Client client,
  required String apiKey,
  required String persona,
  required String language,
}) async {
  final zh = language == 'zh';
  final system = zh
      ? '你在为一个陪伴角色写她被触碰、或使用小屋里的东西时脱口而出的短句。'
            '完全按下面的人设说话：语气、自称、口癖都要像她，不要套用别的角色的身份、外形或物品。'
            '每个场景写 3 句，每句不超过 16 个字。只输出一个 JSON 对象，键是场景名，值是字符串数组。'
      : 'You write the short things a companion character says when touched or when using the things in her room. '
            'Speak exactly as the persona below: her tone, how she refers to herself, her habits; never borrow another '
            "character's identity, looks or belongings. Write 3 lines per moment, each at most 60 characters. Output "
            'only one JSON object whose keys are the moment names and whose values are arrays of strings.';
  final request = StringBuffer()
    ..writeln(zh ? '人设：' : 'Persona:')
    ..writeln(persona)
    ..writeln()
    ..writeln(zh ? '场景：' : 'Moments:');
  for (final entry in CompanionLines.moments.entries) {
    request.writeln('- ${entry.key}: ${entry.value}');
  }
  final text = StringBuffer();
  await for (final delta in streamCompanionReply(
    client: client,
    apiKey: apiKey,
    system: system,
    lines: [CompanionLine.user(request.toString())],
    maxTokens: 1600,
  )) {
    text.write(delta);
  }
  final raw = text.toString();
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw.substring(start, end + 1));
  } on FormatException {
    return null;
  }
  final lines = CompanionLines.parse(decoded);
  return lines.isEmpty ? null : lines;
}
