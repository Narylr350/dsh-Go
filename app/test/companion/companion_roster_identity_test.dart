import 'dart:convert';

import 'package:dsh_app/companion/companion_roster.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences(super.data) : super.withData();

  final snapshots = <Map<String, Object>>[];

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    final result = await super.setValue(type, key, value);
    snapshots.add(await getAll());
    return result;
  }

  @override
  Future<bool> remove(String key) async {
    final result = await super.remove(key);
    snapshots.add(await getAll());
    return result;
  }
}

void main() {
  final originalPlatform = SharedPreferencesStorePlatform.instance;
  tearDown(() {
    SharedPreferencesStorePlatform.instance = originalPlatform;
    SharedPreferences.resetStatic();
  });
  final oldData = <String, Object>{
    'flutter.companion_identity_owner': 'Ann',
    'flutter.companion_name': '阿安',
    'flutter.companion_persona_v1': jsonEncode({'custom': 'Ann persona', 'callMe': '小林'}),
    'flutter.companion_identity_v1:Bea': jsonEncode({'name': '阿贝', 'custom': 'Bea persona'}),
  };

  Future<(_Preferences, WidgetRef)> open(WidgetTester tester, Map<String, Object> data) async {
    await tester.pumpWidget(const SizedBox());
    final store = _Preferences(data);
    SharedPreferencesStorePlatform.instance = store;
    SharedPreferences.resetStatic();
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (_, value, _) {
            ref = value;
            return const SizedBox();
          },
        ),
      ),
    );
    return (store, ref);
  }

  void check(WidgetRef ref, String? name, String custom) {
    expect(ref.read(companionNameProvider), name);
    expect(ref.read(companionPersonaProvider).custom, custom);
    expect(ref.read(companionPersonaProvider).callMe, '小林');
  }

  for (final forget in [false, true]) {
    testWidgets('reopening after every persisted identity write, forget=$forget', (tester) async {
      final (original, ref) = await open(tester, oldData);
      if (forget) {
        await companionForgetIdentity(ref, 'Ann');
      } else {
        await companionAdoptIdentity(ref, 'Bea');
      }
      expect(original.snapshots, isNotEmpty);
      for (final snapshot in original.snapshots) {
        final (store, restarted) = await open(tester, snapshot);
        await companionAdoptIdentity(restarted, 'Bea');
        check(restarted, '阿贝', 'Bea persona');
        final count = store.snapshots.length;
        await companionAdoptIdentity(restarted, 'Bea');
        expect(store.snapshots, hasLength(count));
        await companionAdoptIdentity(restarted, 'Ann');
        check(restarted, forget ? null : '阿安', forget ? '' : 'Ann persona');
      }
    });
  }

  testWidgets('a first legacy owner inherits existing settings and forgetting a shelved role keeps them', (
    tester,
  ) async {
    final legacy = Map.of(oldData)..remove('flutter.companion_identity_owner');
    final (_, ref) = await open(tester, legacy);
    await companionAdoptIdentity(ref, 'Ann');
    check(ref, '阿安', 'Ann persona');
    await companionForgetIdentity(ref, 'Bea');
    check(ref, '阿安', 'Ann persona');
    await companionAdoptIdentity(ref, 'Bea');
    check(ref, null, '');
    await companionAdoptIdentity(ref, 'Ann');
    check(ref, '阿安', 'Ann persona');
  });
}
