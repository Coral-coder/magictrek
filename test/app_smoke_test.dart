import 'package:flutter/material.dart' hide Card;
import 'package:flutter_test/flutter_test.dart';
import 'package:magictrek/app/store.dart';
import 'package:magictrek/main.dart';
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
}
