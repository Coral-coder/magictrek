import 'dart:async';

import 'package:flutter/material.dart' hide Card;
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../app/sound.dart';
import '../app/store.dart';
import '../engine/decks.dart';
import '../net/ble.dart';
import '../net/lan.dart';
import '../net/protocol.dart';
import '../net/relay.dart';
import '../net/transport.dart';
import 'lcars.dart';

/// A horizontal row of deck choices.
class DeckPicker extends StatelessWidget {
  const DeckPicker({super.key, required this.selected, required this.onSelect});
  final Deck? selected;
  final void Function(Deck) onSelect;
  @override
  Widget build(BuildContext context) {
    final store = AppStore.shared;
    return SizedBox(
      height: 62,
      child: ListView(scrollDirection: Axis.horizontal, children: [
        for (final d in store.legalDecks)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: SizedBox(
              width: 130,
              child: LcarsButton(d.name, height: 58, color: d.isStarter ? LCARS.lavender : LCARS.peach, fill: selected?.id == d.id, onPressed: () {
                Console.shared.play(Fx.tap);
                onSelect(d);
              }),
            ),
          ),
      ]),
    );
  }
}

/// Pick decks for a game against the computer or on one device.
class NewGameScreen extends StatefulWidget {
  const NewGameScreen({super.key, required this.hotseat});
  final bool hotseat;
  @override
  State<NewGameScreen> createState() => _NewGameScreenState();
}

class _NewGameScreenState extends State<NewGameScreen> {
  Deck? deck, opponentDeck;

  @override
  void initState() {
    super.initState();
    final legal = AppStore.shared.legalDecks;
    deck = legal.isNotEmpty ? legal.first : null;
    opponentDeck = legal.length > 1 ? legal[1] : deck;
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.shared;
    return LcarsFrame(
      title: widget.hotseat ? 'Pass & Play' : 'Versus Computer',
      subtitle: 'choose decks',
      color: widget.hotseat ? LCARS.butterscotch : LCARS.orange,
      onBack: () => Navigator.pop(context),
      child: ListView(padding: const EdgeInsets.only(bottom: 30), children: [
        if (store.savedGame != null)
          LcarsPanel(
            title: 'Saved game',
            color: LCARS.gold,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('A local game is in progress. Starting a new one replaces it.', style: LCARS.label),
              const SizedBox(height: 4),
              LcarsButton('Resume it instead', color: LCARS.gold, height: 34, onPressed: () {
                if (store.resumeLocalGame() != null) Navigator.pushReplacementNamed(context, '/game');
              }),
            ]),
          ),
        LcarsHeader(widget.hotseat ? 'Player 1 deck' : 'Your deck', color: LCARS.peach),
        DeckPicker(selected: deck, onSelect: (d) => setState(() => deck = d)),
        LcarsHeader(widget.hotseat ? 'Player 2 deck' : "Computer's deck", color: LCARS.lavender),
        DeckPicker(selected: opponentDeck, onSelect: (d) => setState(() => opponentDeck = d)),
        const SizedBox(height: 12),
        LcarsButton('Engage', height: 50, onPressed: deck == null || opponentDeck == null
            ? null
            : () {
                Console.shared.play(Fx.confirm);
                store.startLocalGame(deck: deck!, opponentDeck: opponentDeck!, hotseat: widget.hotseat);
                Navigator.pushReplacementNamed(context, '/game');
              }),
        const SizedBox(height: 8),
        Text('Decks need 60 cards. The computer plays any legal deck.', style: LCARS.small.copyWith(color: LCARS.gray)),
      ]),
    );
  }
}

/// Nearby play: host over Wi‑Fi or Bluetooth, or find a host and join. No server anywhere.
class LocalLobbyScreen extends StatefulWidget {
  const LocalLobbyScreen({super.key});
  @override
  State<LocalLobbyScreen> createState() => _LocalLobbyScreenState();
}

class _LocalLobbyScreenState extends State<LocalLobbyScreen> {
  Deck? deck;
  LinkKind kind = LinkKind.lan;
  HostLink? host;
  GuestLink? guest;
  List<PeerInfo> peers = [];
  String status = '';
  bool hosting = false, scanning = false, busy = false;
  final List<StreamSubscription> _subs = [];
  final addressController = TextEditingController();

  @override
  void initState() {
    super.initState();
    deck = AppStore.shared.legalDecks.firstOrNull;
  }

  @override
  void dispose() {
    _stopAll();
    addressController.dispose();
    super.dispose();
  }

  Future<void> _stopAll() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await host?.stop();
    await guest?.stopScan();
    host = null;
    guest = null;
  }

  Future<void> startHosting() async {
    await _stopAll();
    final store = AppStore.shared;
    final h = kind == LinkKind.lan ? LanHost() : BleHost();
    setState(() {
      hosting = true;
      scanning = false;
      status = 'Starting…';
    });
    try {
      await h.start(name: store.playerName, id: store.deviceId);
      host = h;
      _subs.add(h.connections.listen(_onConnected));
      setState(() => status = kind == LinkKind.lan ? 'Hosting on Wi‑Fi as ${store.playerName}${h is LanHost ? ' (port ${h.port})' : ''}. Waiting for a player…' : 'Hosting over Bluetooth as ${store.playerName}. Waiting for a player…');
    } catch (e) {
      setState(() {
        hosting = false;
        status = 'Could not host: $e';
      });
    }
  }

  Future<void> startScanning() async {
    await _stopAll();
    final g = kind == LinkKind.lan ? LanGuest() : BleGuest();
    setState(() {
      scanning = true;
      hosting = false;
      peers = [];
      status = 'Looking for hosts…';
    });
    try {
      await g.startScan();
      guest = g;
      _subs.add(g.peers.listen((p) => setState(() => peers = p)));
    } catch (e) {
      setState(() {
        scanning = false;
        status = 'Could not scan: $e';
      });
    }
  }

  Future<void> join(PeerInfo peer) async {
    final g = guest;
    if (g == null || busy) return;
    setState(() {
      busy = true;
      status = 'Connecting to ${peer.name}…';
    });
    try {
      final t = await g.connect(peer);
      await g.stopScan();
      _begin(t, isHost: false);
    } catch (e) {
      setState(() {
        busy = false;
        status = 'Could not connect: $e';
      });
    }
  }

  Future<void> joinAddress() async {
    final text = addressController.text.trim();
    final parts = text.split(':');
    if (parts.length != 2 || int.tryParse(parts[1]) == null) {
      setState(() => status = 'Enter host:port, e.g. 192.168.1.20:47000');
      return;
    }
    setState(() {
      busy = true;
      status = 'Connecting to $text…';
    });
    try {
      final t = await LanGuest().connectTo(parts[0], int.parse(parts[1]));
      _begin(t, isHost: false);
    } catch (e) {
      setState(() {
        busy = false;
        status = 'Could not connect: $e';
      });
    }
  }

  void _onConnected(Transport t) {
    setState(() => status = 'A player connected. Linking…');
    _begin(t, isHost: true);
  }

  void _begin(Transport t, {required bool isHost}) {
    final store = AppStore.shared;
    final d = deck;
    if (d == null) return;
    final match = LockstepMatch(transport: t, db: store.db, localName: store.playerName, localId: store.deviceId, localDeck: d.cardList, isHost: isHost, rules: store.rules);
    late StreamSubscription sub;
    sub = match.events.listen((e) {
      if (e == 'start' || (e == 'hello' && match.game != null)) {
        if (match.game == null) return;
        sub.cancel();
        _subs.remove(sub);
        host?.stop();
        host = null;
        store.startLinkedGame(match);
        Console.shared.play(Fx.confirm);
        if (mounted) Navigator.pushReplacementNamed(context, '/game');
      } else if (e == 'error') {
        setState(() {
          busy = false;
          status = match.error ?? 'Link failed';
        });
      }
    });
    _subs.add(sub);
    match.begin();
    // The host builds the game as soon as it hears the guest; make sure we move on then too.
    Timer(const Duration(milliseconds: 300), () {
      if (match.game != null && mounted && store.session?.match != match) {
        sub.cancel();
        _subs.remove(sub);
        host?.stop();
        host = null;
        store.startLinkedGame(match);
        Navigator.pushReplacementNamed(context, '/game');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LcarsFrame(
      title: 'Nearby Play',
      subtitle: 'no server',
      color: LCARS.butterscotch,
      blocks: const [LCARS.orange, LCARS.peach, LCARS.lavender, LCARS.blue, LCARS.gold],
      onBack: () => Navigator.pop(context),
      child: ListView(padding: const EdgeInsets.only(bottom: 30), children: [
        Text('Both phones on the same Wi‑Fi, or Bluetooth with no network at all. One player hosts, the other joins.', style: LCARS.label),
        const LcarsHeader('Link', color: LCARS.orange),
        Row(children: [
          Expanded(child: LcarsButton('Wi‑Fi / LAN', icon: Icons.wifi, height: 36, fill: kind == LinkKind.lan, onPressed: () => setState(() => kind = LinkKind.lan))),
          const SizedBox(width: 6),
          Expanded(child: LcarsButton('Bluetooth', icon: Icons.bluetooth, height: 36, fill: kind == LinkKind.bluetooth, onPressed: () => setState(() => kind = LinkKind.bluetooth))),
        ]),
        const LcarsHeader('Your deck', color: LCARS.peach),
        DeckPicker(selected: deck, onSelect: (d) => setState(() => deck = d)),
        const LcarsHeader('Host', color: LCARS.gold),
        LcarsButton(hosting ? 'Hosting… (tap to stop)' : 'Host a game', color: LCARS.gold, onPressed: deck == null
            ? null
            : () async {
                if (hosting) {
                  await _stopAll();
                  setState(() {
                    hosting = false;
                    status = '';
                  });
                } else {
                  startHosting();
                }
              }),
        const LcarsHeader('Join', color: LCARS.lavender),
        LcarsButton(scanning ? 'Scanning… (tap to stop)' : 'Find hosts nearby', color: LCARS.lavender, onPressed: deck == null
            ? null
            : () async {
                if (scanning) {
                  await _stopAll();
                  setState(() {
                    scanning = false;
                    status = '';
                  });
                } else {
                  startScanning();
                }
              }),
        for (final p in peers) Padding(padding: const EdgeInsets.only(top: 6), child: LcarsButton('${p.name}  ·  ${p.kind == LinkKind.lan ? p.address : 'Bluetooth'}', icon: Icons.login, color: LCARS.ice, onPressed: busy ? null : () => join(p))),
        if (kind == LinkKind.lan) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: addressController,
                style: LCARS.body,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(isDense: true, filled: true, fillColor: LCARS.panel, border: OutlineInputBorder(borderSide: BorderSide.none), hintText: 'or host address:port'),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(width: 80, child: LcarsButton('Join', height: 36, color: LCARS.lavender, fill: false, onPressed: busy || deck == null ? null : joinAddress)),
          ]),
        ],
        if (status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Row(children: [if (hosting || scanning || busy) const Padding(padding: EdgeInsets.only(right: 8), child: ScanLine()), Expanded(child: Text(status, style: LCARS.label.copyWith(color: LCARS.gold)))])),
      ]),
    );
  }
}

/// Remote play through public relays: share a code, no account, no server of ours.
class RemoteLobbyScreen extends StatefulWidget {
  const RemoteLobbyScreen({super.key});
  @override
  State<RemoteLobbyScreen> createState() => _RemoteLobbyScreenState();
}

class _RemoteLobbyScreenState extends State<RemoteLobbyScreen> {
  Deck? deck;
  final codeController = TextEditingController();
  String status = '';
  String? hostedCode;
  RelayTransport? transport;
  LockstepMatch? match;
  StreamSubscription? sub, relaySub;
  int relaysUp = 0;

  @override
  void initState() {
    super.initState();
    deck = AppStore.shared.legalDecks.firstOrNull;
  }

  @override
  void dispose() {
    sub?.cancel();
    relaySub?.cancel();
    if (AppStore.shared.session?.match != match) match?.dispose();
    codeController.dispose();
    super.dispose();
  }

  Future<void> open(String code, {required bool isHost}) async {
    final store = AppStore.shared;
    final d = deck;
    if (d == null) return;
    await sub?.cancel();
    if (store.session?.match != match) await match?.dispose();
    final t = RelayTransport(code: code, secretKey: store.relayIdentity, relays: store.relays);
    transport = t;
    relaySub?.cancel();
    relaySub = t.relayStatus.listen((m) => setState(() => relaysUp = m.values.where((v) => v).length));
    final m = LockstepMatch(transport: t, db: store.db, localName: store.playerName, localId: store.deviceId, localDeck: d.cardList, isHost: isHost, rules: store.rules);
    match = m;
    setState(() {
      hostedCode = isHost ? code : null;
      status = isHost ? 'Share the code. The game starts when your opponent joins.' : 'Joining $code…';
    });
    store.rememberRemoteMatch(code: code, host: isHost);
    sub = m.events.listen((e) {
      if ((e == 'start' || e == 'hello' || e == 'action') && m.game != null) {
        if (store.session?.match == m) return;
        store.rememberRemoteMatch(code: code, host: isHost, opponent: m.remoteName);
        store.startLinkedGame(m);
        Console.shared.play(Fx.confirm);
        if (mounted) Navigator.pushReplacementNamed(context, '/game');
      } else if (e == 'error') {
        setState(() => status = m.error ?? 'Link failed');
      } else if (e == 'hello') {
        setState(() => status = 'Linked with ${m.remoteName}…');
      }
    });
    m.begin();
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.shared;
    return LcarsFrame(
      title: 'Subspace Link',
      subtitle: 'remote play',
      color: LCARS.blue,
      blocks: const [LCARS.skyBlue, LCARS.lavender, LCARS.peach, LCARS.orange, LCARS.ice],
      onBack: () => Navigator.pop(context),
      child: ListView(padding: const EdgeInsets.only(bottom: 30), children: [
        Text('Play someone anywhere. Moves travel encrypted through public relays, so nobody runs a server and a match can continue days later: open it again and it catches up.', style: LCARS.label),
        const LcarsHeader('Your deck', color: LCARS.peach),
        DeckPicker(selected: deck, onSelect: (d) => setState(() => deck = d)),
        const LcarsHeader('Host a match', color: LCARS.orange),
        LcarsButton('Create a match code', color: LCARS.orange, onPressed: deck == null ? null : () => open(newMatchCode(), isHost: true)),
        if (hostedCode != null)
          LcarsPanel(
            title: 'Match code',
            color: LCARS.gold,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SelectableText(hostedCode!, style: LCARS.font(38, color: LCARS.gold)),
              Row(children: [
                Expanded(child: LcarsButton('Share', icon: Icons.share, height: 34, color: LCARS.gold, onPressed: () => SharePlus.instance.share(ShareParams(text: 'Join my MagicTrek game: code $hostedCode')))),
                const SizedBox(width: 6),
                Expanded(child: LcarsButton('Copy', icon: Icons.copy, height: 34, color: LCARS.gold, fill: false, onPressed: () => Clipboard.setData(ClipboardData(text: hostedCode!)))),
              ]),
            ]),
          ),
        const LcarsHeader('Join a match', color: LCARS.lavender),
        Row(children: [
          Expanded(
            child: TextField(
              controller: codeController,
              style: LCARS.font(22),
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(isDense: true, filled: true, fillColor: LCARS.panel, border: OutlineInputBorder(borderSide: BorderSide.none), hintText: 'CODE'),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(width: 90, child: LcarsButton('Join', color: LCARS.lavender, onPressed: deck == null ? null : () => open(codeController.text.trim().toUpperCase(), isHost: false))),
        ]),
        if (store.remoteMatches.isNotEmpty) const LcarsHeader('Your matches', color: LCARS.skyBlue),
        for (final m in store.remoteMatches)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Expanded(child: LcarsButton('${m['code']}  ·  ${m['host'] == true ? 'hosted' : 'joined'}${m['opponent'] != null ? ' · vs ${m['opponent']}' : ''}', color: LCARS.skyBlue, fill: false, onPressed: deck == null ? null : () => open(m['code'] as String, isHost: m['host'] as bool))),
              IconButton(icon: const Icon(Icons.close, color: LCARS.gray), onPressed: () => store.forgetRemoteMatch(m['code'] as String)),
            ]),
          ),
        if (status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(children: [
              if (match != null && match!.game == null) const Padding(padding: EdgeInsets.only(right: 8), child: ScanLine()),
              Expanded(child: Text('$status${transport != null ? '  ($relaysUp relays connected)' : ''}', style: LCARS.label.copyWith(color: LCARS.gold))),
            ]),
          ),
      ]),
    );
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
