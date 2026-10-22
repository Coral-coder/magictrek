import 'package:flutter/material.dart';

import '../app/store.dart';
import '../app/updater.dart';
import '../engine/rules.dart';
import 'lcars.dart';
import 'update.dart';

class MainMenuScreen extends StatelessWidget {
  const MainMenuScreen({super.key});

  /// A practice game against the computer with the tour of the table and coach hints on:
  /// Starfleet Command against the Klingon Empire.
  static Future<void> startTutorial(BuildContext context) async {
    final store = AppStore.shared;
    await store.setTourSeen(false);
    await store.setCoach(true);
    final decks = store.starterDecks;
    if (decks.length < 2 || !context.mounted) return;
    store.startLocalGame(deck: decks[0], opponentDeck: decks[1], hotseat: false);
    await Navigator.pushNamed(context, '/game');
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.shared;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => LcarsFrame(
        title: 'MagicTrek',
        subtitle: 'LCARS 47',
        child: Stack(children: [
          const Positioned.fill(child: Starfield()),
          ListView(padding: const EdgeInsets.only(bottom: 30, top: 4), children: [
            Text('Multiplayer card battles across the final frontier', style: LCARS.label),
            const SizedBox(height: 8),
            if (store.savedGame != null) ...[
              LcarsButton('Resume game', icon: Icons.play_arrow, color: LCARS.gold, onPressed: () {
                if (store.resumeLocalGame() != null) Navigator.pushNamed(context, '/game');
              }),
              const SizedBox(height: 6),
            ],
            LcarsButton('Tutorial: learn to play', icon: Icons.school, color: LCARS.green, onPressed: () => startTutorial(context)),
            const SizedBox(height: 6),
            LcarsButton('Play vs Computer', icon: Icons.memory, onPressed: () => Navigator.pushNamed(context, '/new', arguments: false)),
            const SizedBox(height: 6),
            LcarsButton('Pass & Play', icon: Icons.people, color: LCARS.butterscotch, onPressed: () => Navigator.pushNamed(context, '/new', arguments: true)),
            const SizedBox(height: 6),
            LcarsButton('Nearby: Wi‑Fi or Bluetooth', icon: Icons.bluetooth, color: LCARS.gold, onPressed: () => Navigator.pushNamed(context, '/local')),
            const SizedBox(height: 6),
            LcarsButton('Remote: Subspace Link', icon: Icons.public, color: LCARS.blue, onPressed: () => Navigator.pushNamed(context, '/remote')),
            const LcarsHeader('Databanks', color: LCARS.lavender),
            LcarsButton('Card Database', icon: Icons.view_module, color: LCARS.lavender, onPressed: () => Navigator.pushNamed(context, '/gallery')),
            const SizedBox(height: 6),
            LcarsButton('Decks', icon: Icons.layers, color: LCARS.violet, onPressed: () => Navigator.pushNamed(context, '/decks')),
            const SizedBox(height: 6),
            LcarsButton('How to Play', icon: Icons.help_outline, color: LCARS.skyBlue, onPressed: () => Navigator.pushNamed(context, '/help')),
            const SizedBox(height: 6),
            LcarsButton('Settings', icon: Icons.settings, color: LCARS.peach, fill: false, onPressed: () => Navigator.pushNamed(context, '/settings')),
            const SizedBox(height: 14),
            Text('Card images: mythicspoiler.com · card data: Scryfall · Magic: The Gathering is a trademark of Wizards of the Coast; Star Trek of CBS Studios. Fan project, not affiliated.', style: LCARS.small.copyWith(color: LCARS.gray)),
          ]),
        ]),
      ),
    );
  }
}

class HowToPlayScreen extends StatelessWidget {
  const HowToPlayScreen({super.key});

  static const sections = [
    ('The mission', 'Reduce your opponent from 20 life to 0. Each player brings a 60-card deck of Star Trek cards: crew, starships, planets and events.'),
    ('Lands and mana', 'Play one land each turn (tap it in your hand). Lands tap for mana, which pays for spells. The game taps lands for you when you cast.'),
    ('A turn', 'Untap, draw, then your main phase: play a land, cast creatures and spells. Then attack with creatures that have been under your control since the start of your turn. After combat, a second main phase, then End Turn.'),
    ('Combat', 'Tap Attack, pick attackers, confirm. The defender assigns blockers: tap a blocker, then the attacker it blocks. Unblocked attackers hit the player. Flying creatures can only be blocked by flying or reach.'),
    ('Spacecraft', 'Starships enter as artifacts. Station them: tap one of your creatures to add charge counters equal to its power. At the threshold (for example 5+) the ship becomes an artifact creature with the listed abilities.'),
    ('Keywords', 'Flying, first strike, double strike, deathtouch, lifelink, trample, haste, vigilance, menace, reach, defender, ward, hexproof and indestructible all work as printed.'),
    ('Decisions', 'When a card asks you something (a target, a mode, surveil, discard) the question appears in the middle bar with its answers as buttons. When you must pick cards, the ones you can pick glow gold.'),
    ('Sagas, Borg, Landfall', 'Sagas gain a lore counter each turn and tell their story. Borg cards assimilate creature cards from graveyards. Landfall triggers when a land enters under your control.'),
    ('Nearby play', 'Both phones on one Wi‑Fi, or Bluetooth with no network: one hosts, the other joins. Every move is checked on both phones, so the game can never drift apart.'),
    ('Remote play', 'Create a code and send it to a friend anywhere. Moves travel encrypted through public relays; nobody runs a server. Leave and come back later: the match catches up from the relays.'),
    ('Reading cards', 'Tap any card on the table or in your hand to see it large, with buttons for what you can do with it. If nothing can be done, it says why (not enough mana, wrong phase…).'),
    ('Card coverage', 'Every card in the set plays its printed rules text.'),
  ];

  @override
  Widget build(BuildContext context) => LcarsFrame(
        title: 'How to Play',
        subtitle: 'briefing',
        color: LCARS.skyBlue,
        blocks: const [LCARS.blue, LCARS.lavender, LCARS.peach, LCARS.orange, LCARS.ice],
        onBack: () => Navigator.pop(context),
        child: ListView(padding: const EdgeInsets.only(bottom: 30), children: [
          for (var i = 0; i < sections.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: LcarsPanel(title: sections[i].$1, color: LCARS.palette[i % LCARS.palette.length], child: Text(sections[i].$2, style: const TextStyle(fontSize: 15, color: LCARS.peach))),
            ),
        ]),
      );
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController name = TextEditingController(text: AppStore.shared.playerName);
  late final TextEditingController relays = TextEditingController(text: AppStore.shared.relays.join('\n'));

  @override
  void dispose() {
    name.dispose();
    relays.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.shared;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => LcarsFrame(
        title: 'Settings',
        subtitle: 'ship systems',
        color: LCARS.peach,
        blocks: const [LCARS.orange, LCARS.lavender, LCARS.blue, LCARS.gold, LCARS.skyBlue],
        onBack: () => Navigator.pop(context),
        child: ListView(padding: const EdgeInsets.only(bottom: 30), children: [
          const LcarsHeader('Captain', color: LCARS.orange),
          TextField(
            controller: name,
            style: LCARS.heading,
            decoration: const InputDecoration(isDense: true, filled: true, fillColor: LCARS.panel, border: OutlineInputBorder(borderSide: BorderSide.none), hintText: 'Your name'),
            onChanged: store.setPlayerName,
          ),
          const LcarsHeader('Console', color: LCARS.lavender),
          SwitchListTile(title: Text('Console sounds', style: LCARS.body), value: store.soundOn, activeThumbColor: LCARS.orange, onChanged: store.setSound, contentPadding: EdgeInsets.zero),
          SwitchListTile(title: Text('Haptics', style: LCARS.body), value: store.hapticsOn, activeThumbColor: LCARS.orange, onChanged: store.setHaptics, contentPadding: EdgeInsets.zero),
          const LcarsHeader('Table', color: LCARS.skyBlue),
          SwitchListTile(
            title: Text('Tap a card to see it first', style: LCARS.body),
            subtitle: Text('Tapping a card shows it large with what you can do. Off: tapping plays it straight away.', style: LCARS.label),
            value: store.tapToInspect,
            activeThumbColor: LCARS.orange,
            onChanged: store.setTapToInspect,
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            title: Text('Coach hints', style: LCARS.body),
            subtitle: Text('A line on the table saying what you can do right now.', style: LCARS.label),
            value: store.coachOn,
            activeThumbColor: LCARS.orange,
            onChanged: store.setCoach,
            contentPadding: EdgeInsets.zero,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => store.setTourSeen(false), child: Text('Show the table tour again in the next game', style: LCARS.label.copyWith(color: LCARS.skyBlue))),
          ),
          const LcarsHeader('Rules', color: LCARS.butterscotch),
          Text('How new games are played. The host\'s rules apply to a linked match; a saved game keeps the rules it started with.', style: LCARS.label),
          const SizedBox(height: 6),
          _RuleChoice(label: 'Starting life', value: store.rules.startingLife, options: const [20, 25, 30, 40], onChanged: (v) => store.setRules(store.rules.copyWith(startingLife: v))),
          _RuleChoice(label: 'Opening hand', value: store.rules.handSize, options: const [5, 6, 7, 8], onChanged: (v) => store.setRules(store.rules.copyWith(handSize: v))),
          _RuleSwitch('London mulligan', 'Redraw a full hand, then put one card per mulligan on the bottom. Off: each mulligan draws one card fewer.', store.rules.londonMulligan, (v) => store.setRules(store.rules.copyWith(londonMulligan: v))),
          _RuleSwitch('First mulligan is free', 'The Commander convention.', store.rules.freeMulligan, (v) => store.setRules(store.rules.copyWith(freeMulligan: v))),
          _RuleSwitch('First player draws on turn one', 'Normally the player going first skips that draw.', store.rules.firstPlayerDraws, (v) => store.setRules(store.rules.copyWith(firstPlayerDraws: v))),
          _RuleSwitch('Maximum hand size', 'Discard down to the opening-hand size at end of turn.', store.rules.maxHandSize, (v) => store.setRules(store.rules.copyWith(maxHandSize: v))),
          if (!store.rules.isStandard) ...[
            const SizedBox(height: 4),
            LcarsButton('Standard rules', color: LCARS.butterscotch, fill: false, height: 32, expand: false, onPressed: () => store.setRules(Rules.standard)),
          ],
          const LcarsHeader('Relays', color: LCARS.blue),
          Text('Remote play sends moves through these public Nostr relays, one per line. Any relay works, including your own.', style: LCARS.label),
          const SizedBox(height: 4),
          TextField(
            controller: relays,
            style: const TextStyle(fontSize: 13, color: LCARS.peach, fontFamily: 'monospace'),
            maxLines: 5,
            decoration: const InputDecoration(isDense: true, filled: true, fillColor: LCARS.panel, border: OutlineInputBorder(borderSide: BorderSide.none)),
            onChanged: (v) => store.setRelays(v.split('\n')),
          ),
          if (Updater.shared.supported) ...[
            const LcarsHeader('Updates', color: LCARS.green),
            Text('Builds are published on GitHub Releases. The app checks on launch and when it returns to the foreground, fetches a newer build in the background and installs it over itself with one tap.', style: LCARS.label),
            SwitchListTile(title: Text('Download new builds automatically', style: LCARS.body), value: store.autoUpdate, activeThumbColor: LCARS.green, onChanged: store.setAutoUpdate, contentPadding: EdgeInsets.zero),
            ListenableBuilder(
              listenable: Updater.shared,
              builder: (context, _) {
                final u = Updater.shared;
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  LcarsButton(u.checking ? 'Checking…' : 'Check for updates', icon: Icons.system_update, color: LCARS.green, fill: false, height: 36, onPressed: u.checking ? null : () async {
                    final release = await u.check();
                    if (!context.mounted) return;
                    if (release != null) {
                      UpdateDialog.show(context, release);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(u.error ?? 'Up to date: ${u.installedVersion} (build ${u.installedCode})')));
                    }
                  }),
                  if (u.installedCode > 0) ...[const SizedBox(height: 4), Text('Installed ${u.installedVersion} (build ${u.installedCode})', style: LCARS.small.copyWith(color: LCARS.gray))],
                ]);
              },
            ),
          ],
          const LcarsHeader('Data', color: LCARS.gold),
          LcarsButton('Restore starter decks', color: LCARS.gold, fill: false, height: 36, onPressed: store.restoreStarterDecks),
          if (store.savedGame != null) ...[const SizedBox(height: 6), LcarsButton('Discard saved game', color: LCARS.red, fill: false, height: 36, onPressed: store.clearSavedGame)],
          const SizedBox(height: 12),
          Text('Card database generated ${store.db.generated}. ${store.db.distinctCards.length} cards, ${store.db.fullySupportedCards.length} fully playable. Device id ${store.deviceId}.', style: LCARS.small.copyWith(color: LCARS.gray)),
          const SizedBox(height: 6),
          Text('MagicTrek is a fan project. Card images from mythicspoiler.com, card data from Scryfall. Magic: The Gathering © Wizards of the Coast. Star Trek © CBS Studios.', style: LCARS.small.copyWith(color: LCARS.gray)),
        ]),
      ),
    );
  }
}


class _RuleSwitch extends StatelessWidget {
  const _RuleSwitch(this.title, this.subtitle, this.value, this.onChanged);
  final String title, subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => SwitchListTile(
        title: Text(title, style: LCARS.body),
        subtitle: Text(subtitle, style: LCARS.small.copyWith(color: LCARS.gray)),
        value: value,
        activeThumbColor: LCARS.butterscotch,
        onChanged: onChanged,
        contentPadding: EdgeInsets.zero,
        dense: true,
      );
}

class _RuleChoice extends StatelessWidget {
  const _RuleChoice({required this.label, required this.value, required this.options, required this.onChanged});
  final String label;
  final int value;
  final List<int> options;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(label, style: LCARS.body)),
          for (final o in options) ...[
            SizedBox(width: 46, child: LcarsButton('$o', height: 28, color: LCARS.butterscotch, fill: o == value, onPressed: () => onChanged(o))),
            const SizedBox(width: 4),
          ],
        ]),
      );
}
