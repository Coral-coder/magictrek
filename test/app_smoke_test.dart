import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';
import 'package:magictrek/app/store.dart';
import 'package:magictrek/engine/abilities.dart';
import 'package:magictrek/engine/cards.dart';
import 'package:magictrek/engine/game.dart';
import 'package:magictrek/engine/state.dart';
import 'package:magictrek/main.dart';
import 'package:magictrek/ui/card_widgets.dart';
import 'package:magictrek/ui/decks.dart';
import 'package:magictrek/ui/gallery.dart';
import 'package:magictrek/ui/game_screen.dart';
import 'package:magictrek/ui/lcars.dart';
import 'package:magictrek/ui/lobbies.dart';
import 'package:magictrek/ui/menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Boots the real screens with the real card database, so layout and wiring mistakes show up here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppStore.shared.init();
  });

  Widget app(Widget home) => MaterialApp(theme: LCARS.theme(), home: home);

  testWidgets('main menu renders and navigates', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MagicTrekApp());
    await tester.pump();
    expect(find.text('PLAY VS COMPUTER'), findsOneWidget);
    await tester.tap(find.text('CARD DATABASE'));
    await tester.pumpAndSettle();
    expect(find.byType(CardGalleryScreen), findsOneWidget);
  });

  testWidgets('a remote match can be removed from the list', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await AppStore.shared.rememberRemoteMatch(code: 'ZZTOP9', host: true, opponent: 'Worf');
    await tester.pumpWidget(app(const RemoteLobbyScreen()));
    await tester.pump();
    final row = find.textContaining('ZZTOP9');
    expect(row, findsOneWidget);
    await tester.tap(find.byTooltip('Remove this match'));
    await tester.pumpAndSettle();
    expect(row, findsNothing);
    expect(AppStore.shared.remoteMatches.where((m) => m['code'] == 'ZZTOP9'), isEmpty);
  });

  testWidgets('gallery, decks and lobbies build', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(const CardGalleryScreen()));
    await tester.pump();
    await tester.pumpWidget(app(const DeckListScreen()));
    await tester.pump();
    expect(find.text('STARTER DECKS'), findsOneWidget);
    final starter = AppStore.shared.starterDecks.first;
    await tester.pumpWidget(app(DeckEditorScreen(deckID: starter.id)));
    await tester.pump();
    await tester.pumpWidget(app(const NewGameScreen(hotseat: false)));
    await tester.pump();
    expect(find.text('ENGAGE'), findsOneWidget);
    await tester.pumpWidget(app(const LocalLobbyScreen()));
    await tester.pump();
    await tester.pumpWidget(app(const RemoteLobbyScreen()));
    await tester.pump();
    await tester.pumpWidget(app(const HowToPlayScreen()));
    await tester.pump();
    await tester.pumpWidget(app(const SettingsScreen()));
    await tester.pump();
  });

  testWidgets('a solo game plays on the table', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final store = AppStore.shared;
    final decks = store.legalDecks;
    final session = store.startLocalGame(deck: decks[0], opponentDeck: decks[1], hotseat: false);
    await tester.pumpWidget(app(const GameScreen()));
    await tester.pump();
    // First game: the tour of the table shows. Walk through it.
    expect(find.text('WELCOME ABOARD'), findsOneWidget);
    for (var i = 0; i < 10 && find.text('GOT IT').evaluate().isEmpty; i++) {
      await tester.tap(find.text('NEXT'));
      await tester.pump();
    }
    await tester.tap(find.text('GOT IT'));
    await tester.pump();
    expect(store.tourSeen, isTrue);
    // Tapping a card in hand shows it large, with a way out.
    await tester.tap(find.byKey(ValueKey('hand-${session.state.players[0].hand.first}')));
    await tester.pumpAndSettle();
    expect(find.text('RULES & DETAILS'), findsOneWidget);
    await tester.tap(find.text('CLOSE'));
    await tester.pumpAndSettle();
    // Answer the mulligan prompts (ours and, via the bot timer, the computer's).
    for (var i = 0; i < 40 && session.state.turn < 3; i++) {
      await tester.pump(const Duration(milliseconds: 700));
      if (find.text('KEEP').evaluate().isNotEmpty) {
        await tester.tap(find.text('KEEP'));
        await tester.pump();
      } else if (find.text('END TURN').evaluate().isNotEmpty) {
        await tester.tap(find.text('END TURN').first);
        await tester.pump();
      } else if (find.text('NO ATTACK').evaluate().isNotEmpty) {
        await tester.tap(find.text('NO ATTACK'));
        await tester.pump();
      } else if (find.text('CONTINUE').evaluate().isNotEmpty) {
        await tester.tap(find.text('CONTINUE'));
        await tester.pump();
      }
    }
    expect(session.state.turn, greaterThanOrEqualTo(2));
    expect(find.byType(GameScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a short, wide screen still shows the opponent\'s cards, with lands as labels or cards', (tester) async {
    tester.view.physicalSize = const Size(844 * 3, 390 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final store = AppStore.shared;
    await store.setTourSeen(true);
    for (final asCards in [false, true]) {
      await store.setShowAllCards(asCards);
      final decks = store.legalDecks;
      final session = store.startLocalGame(deck: decks[0], opponentDeck: decks[1], hotseat: false);
      // Put cards in play on both sides: a creature and a land each.
      final g = session.game;
      for (final p in [0, 1]) {
        for (final name in ['Captain Jean-Luc Picard', 'Plains']) {
          final id = g.newObject(cardID: store.db.byName(name)!.id, owner: p, zone: Zone.hand);
          g.move(id, Zone.battlefield, controller: p);
        }
      }
      await tester.pumpWidget(app(const GameScreen()));
      await tester.pump();
      final theirs = g.state.permanentsOf(1).firstWhere((o) => !g.characteristics(o.id).isLand);
      final card = find.byKey(ValueKey('perm-${theirs.id}'));
      expect(card, findsOneWidget, reason: 'opponent creature shown (lands as cards: $asCards)');
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.textContaining('controls this'), findsOneWidget, reason: 'tapping it opens it to read');
      expect(find.text('CLOSE'), findsOneWidget, reason: 'with its buttons in view');
      Navigator.of(tester.element(find.byType(GameScreen))).pop();
      await tester.pumpAndSettle();
      final theirLand = g.state.permanentsOf(1).firstWhere((o) => g.characteristics(o.id).isLand);
      expect(find.byKey(ValueKey('perm-${theirLand.id}')), asCards ? findsOneWidget : findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    }
    await store.setShowAllCards(true);
  });

  testWidgets('tokens are drawn as cards, and the table button switches lands between cards and labels', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final store = AppStore.shared;
    await store.setTourSeen(true);
    await store.setShowAllCards(true);
    final decks = store.legalDecks;
    final session = store.startLocalGame(deck: decks[0], opponentDeck: decks[1], hotseat: false);
    final g = session.game;
    final officer = g.createToken(TokenSpec(name: 'Officer', power: 1, toughness: 1, colors: [ManaColor.red], subtypes: ['Officer']), 1);
    final treasure = g.createToken(TokenSpec.treasure, 1);
    final land = g.newObject(cardID: store.db.byName('Plains')!.id, owner: 0, zone: Zone.hand);
    g.move(land, Zone.battlefield, controller: 0);
    await tester.pumpWidget(app(const GameScreen()));
    await tester.pump();
    // The Officer has no printed scan: it is drawn as a card with its name, type and power/toughness.
    final officerCard = find.byKey(ValueKey('perm-$officer'));
    expect(find.descendant(of: officerCard, matching: find.byType(TokenFace)), findsOneWidget);
    expect(find.descendant(of: officerCard, matching: find.text('Token Creature — Officer')), findsOneWidget);
    // The Treasure uses its printed scan.
    expect(find.descendant(of: find.byKey(ValueKey('perm-$treasure')), matching: find.byType(TokenFace)), findsNothing);
    expect(find.byKey(ValueKey('perm-$land')), findsOneWidget, reason: 'lands show as cards by default');
    await tester.tap(find.byKey(const ValueKey('show-all-cards')));
    await tester.pump();
    expect(store.showAllCards, isFalse);
    expect(find.byKey(ValueKey('perm-$land')), findsNothing);
    expect(find.byKey(const ValueKey('land-Plains')), findsOneWidget, reason: 'now a label');
    await tester.tap(find.byKey(const ValueKey('show-all-cards')));
    await tester.pump();
    expect(store.showAllCards, isTrue);
    expect(find.byKey(ValueKey('perm-$land')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
