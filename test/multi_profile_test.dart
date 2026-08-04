// Multiple Nostr profiles: the legacy single profile becomes the first
// slot with no data migration, extra slots keep their own keys, the active
// slot is remembered, and an existing identity can be imported by nsec.
import 'package:bip340/bip340.dart' as bip340;
import 'package:einkreader/services/nostr_service.dart';
import 'package:einkreader/services/profile_service.dart';
import 'package:einkreader/widgets/profile_switcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ProfileService.instance.debugPublish = (event) async => 1;
    ProfileService.instance.debugFetchProfile = (npub) async => null;
    ProfileService.instance.debugResetActiveCache();
  });

  test('a legacy single profile becomes the first slot, untouched',
      () async {
    // Prefs exactly as a pre-multi-profile install left them.
    SharedPreferences.setMockInitialValues({
      'profile_secret_key': 'a' * 64,
      'profile_name': 'Xavier',
    });
    final service = ProfileService.instance;
    final summaries = await service.profileSummaries();
    expect(summaries, hasLength(1));
    expect(summaries.single.id, 'default');
    expect(summaries.single.name, 'Xavier');
    expect(summaries.single.active, isTrue);
    expect(summaries.single.hasIdentity, isTrue);
    expect(await service.enabled, isTrue);
    expect((await service.profile()).name, 'Xavier');
  });

  test('slots are isolated; the last used profile is remembered', () async {
    SharedPreferences.setMockInitialValues({});
    final service = ProfileService.instance;
    await service.createIdentity();
    await service.saveProfile(const Profile(name: 'Personal'));
    final personalNpub = await service.npub;

    // A second slot: fresh identity, own fields.
    final workId = await service.addProfileSlot();
    expect(await service.enabled, isFalse,
        reason: 'a new slot starts without an identity');
    await service.createIdentity();
    await service.saveProfile(const Profile(name: 'Work'));
    expect((await service.profile()).name, 'Work');
    expect(await service.npub, isNot(personalNpub));

    // The choice persists in prefs (survives restarts).
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('active_profile_id'), workId);

    // Switching back restores the first slot exactly.
    await service.switchTo('default');
    expect((await service.profile()).name, 'Personal');
    expect(await service.npub, personalNpub);
    expect(prefs.getString('active_profile_id'), 'default');
  });

  test('importNsec round-trips the identity into a new active slot',
      () async {
    SharedPreferences.setMockInitialValues({});
    final service = ProfileService.instance;
    final secret = _hex(List.generate(32, (i) => (i * 11 + 7) & 0xff));
    final nsec = NostrService.bech32Encode(
        'nsec',
        List.generate(32, (i) => (i * 11 + 7) & 0xff));

    await service.importNsec(nsec);
    expect(await service.publicKeyHex, bip340.getPublicKey(secret));
    final summaries = await service.profileSummaries();
    expect(summaries, hasLength(2)); // default + imported
    expect(summaries.last.active, isTrue);

    // Garbage is rejected with a readable error.
    expect(service.importNsec('npub1notasecret'), throwsFormatException);
    expect(service.importNsec('hello'), throwsFormatException);
  });

  test('imported metadata is pulled best-effort', () async {
    SharedPreferences.setMockInitialValues({});
    final service = ProfileService.instance;
    service.debugFetchProfile = (npub) async => NostrProfile(
        pubkey: 'x', name: 'Imported Name', about: 'bio', picture: '');
    await service.importNsec(NostrService.bech32Encode(
        'nsec', List.generate(32, (i) => (i * 3 + 1) & 0xff)));
    expect((await service.profile()).name, 'Imported Name');
    expect((await service.profile()).about, 'bio');
  });

  testWidgets('long-press switcher lists profiles and Add profile…',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final service = ProfileService.instance;
    await service.createIdentity();
    await service.saveProfile(const Profile(name: 'Personal'));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: GestureDetector(
              onLongPress: () => showProfileSwitcherMenu(context),
              child: const Icon(Icons.account_circle_outlined),
            ),
          ),
        ),
      ),
    ));
    await tester.longPress(find.byIcon(Icons.account_circle_outlined));
    await tester.pumpAndSettle();

    expect(find.text('✓ Personal'), findsOneWidget);
    expect(find.text('Add profile…'), findsOneWidget);

    // "Add profile…" opens the create/import chooser with the quiet
    // advanced link.
    await tester.tap(find.text('Add profile…'));
    await tester.pumpAndSettle();
    expect(find.text('Create a new profile'), findsOneWidget);
    expect(find.text('Import an existing profile'), findsOneWidget);
    await tester.tap(find.text('Import an existing profile'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'nsec'), findsOneWidget);
  });
}
