import 'package:flutter/material.dart';

import 'app/notifications.dart';
import 'app/store.dart';
import 'ui/decks.dart';
import 'ui/gallery.dart';
import 'ui/game_screen.dart';
import 'ui/lcars.dart';
import 'ui/lobbies.dart';
import 'ui/menu.dart';
import 'ui/update.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MagicTrekApp());
}

class MagicTrekApp extends StatefulWidget {
  const MagicTrekApp({super.key});
  @override
  State<MagicTrekApp> createState() => _MagicTrekAppState();
}

class _MagicTrekAppState extends State<MagicTrekApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppStore.shared.init().then((_) => Notifications.shared.requestPermission());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppStore.shared.session?.appInForeground = state == AppLifecycleState.resumed;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MagicTrek',
      theme: LCARS.theme(),
      debugShowCheckedModeBanner: false,
      home: ListenableBuilder(
        listenable: AppStore.shared,
        builder: (context, _) => AppStore.shared.ready ? const UpdateCheck(child: MainMenuScreen()) : const _Loading(),
      ),
      onGenerateRoute: (settings) {
        final args = settings.arguments;
        Widget page;
        switch (settings.name) {
          case '/gallery':
            page = const CardGalleryScreen();
          case '/card':
            page = CardDetailScreen(cardID: args as String);
          case '/decks':
            page = const DeckListScreen();
          case '/deck':
            page = DeckEditorScreen(deckID: args as String);
          case '/new':
            page = NewGameScreen(hotseat: args as bool);
          case '/local':
            page = const LocalLobbyScreen();
          case '/remote':
            page = const RemoteLobbyScreen();
          case '/game':
            page = const GameScreen();
          case '/help':
            page = const HowToPlayScreen();
          case '/settings':
            page = const SettingsScreen();
          default:
            page = const MainMenuScreen();
        }
        return MaterialPageRoute(builder: (_) => page, settings: settings);
      },
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: LCARS.black,
        body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Text('MAGICTREK', style: LCARS.title), const SizedBox(height: 16), const ScanLine(width: 140)])),
      );
}
