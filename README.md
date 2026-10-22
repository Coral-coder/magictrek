# MagicTrek
A Magic: The Gathering–style card game built on the Star Trek set, for iOS and Android from one
Flutter codebase, with an LCARS interface. Play the computer, pass-and-play on one phone, play a
friend nearby over Wi‑Fi or Bluetooth, or play anyone anywhere through public relays. No server.

## Layout

| Path | What |
| --- | --- |
| `assets/images/` | One high-resolution scan per printing (Scryfall's 672×936 "large" image), ~52 MB. |
| `assets/cards.json` | Every printing of every set in the database with its rules data. |
| `tools/build-card-db.py` | Builds both from Scryfall: `--sets trk,trc,ttrk` (the Star Trek set, its Commander decks, its tokens). Add a set code to expand. |
| `cards/` | The mythicspoiler.com scans pulled by the Card images workflow; used only for cards Scryfall doesn't list yet (`tools/card-overrides.json`). |
| `lib/engine/` | The rules: card database, rules-text parser, deterministic game, combat, triggers, computer player, starter decks. Pure Dart. |
| `lib/net/` | Lockstep protocol and transports: LAN (UDP discovery + TCP), Bluetooth LE, Nostr relays. |
| `lib/app/` | App state, sessions, saved games, sounds, notifications. |
| `lib/ui/` | LCARS widgets and screens. |
| `test/` | Engine, networking and widget tests (`flutter test`). |
| `tool/cardtool.dart` | `dart run tool/cardtool.dart` reports parser coverage; `dart run tool/cardtool.dart "Picard"` shows one card. |

## Building

    flutter pub get
    flutter run                      # a connected phone or simulator
    flutter build apk --release      # Android
    flutter build ipa                # iOS (needs signing)

Bundle / application id: `com.lightwave.openmtg`.

## How the game works

- A game is its seed plus an ordered list of actions. Replaying them on any device gives the same
  state; a digest of the state after every action is exchanged, so two phones can never drift
  apart without noticing (lockstep).
- Rules text is parsed into a fixed vocabulary of keywords, triggers, static abilities and effects.
  Cards whose text isn't fully covered still play with their printed stats and whatever did parse;
  the card database screen says what's missing for each card. Starter decks use only fully
  implemented cards.
- Set mechanics: Station (Spacecraft become creatures with enough charge counters), Sagas,
  Landfall, Explore, Surveil, Ward, Kicker, Cycling, Beam me up, Assimilate and Discover.
- The computer player is heuristic: lands by color need, best castable spell, safe attacks, blocks
  that trade well or prevent lethal.

## Multiplayer without a server

Every transport carries the same lockstep protocol (`lib/net/protocol.dart`); the host's phone
picks the seed, both sides exchange decks, and from then on each move is a numbered action.

- **Nearby, Wi‑Fi**: the host broadcasts on UDP port 47474; guests list the hosts they hear and
  connect over TCP. If a network blocks broadcasts, the guest can type the host's `address:port`.
- **Nearby, Bluetooth**: the host advertises a GATT service; the guest scans and connects. One
  characteristic carries both directions, chunked to the link's MTU. Works with no network at all.
- **Remote**: the host makes a 6-letter code. Both phones derive a room tag and an encryption key
  from it and talk through public Nostr relays (configurable in Settings). Relays keep the events,
  so a match can continue days later: open it again and it catches up. Nobody runs a server.

Turn notifications are local: when a move arrives (or the computer finishes) while the app is in
the background, the phone shows "Your move". There is no push service, so the app has to be
running (foreground or background) to notice a remote move.

## Releases

Put the word **build** in a commit subject (`Build: new card art`, `build`, `*u` also works) and
push it on any branch, or push a tag like `v1.2.0`: CI then ships both platforms from that commit.

- **Android**: `.github/workflows/android-release.yml` builds the release APK and publishes a
  GitHub Release (`build-<n>`, or the tag) carrying `MagicTrek.apk` and `update.json`. The link
  <https://github.com/Coral-coder/magictrek/releases/latest/download/MagicTrek.apk> always
  downloads the newest build, so one QR code of it stays valid forever. Installed copies read
  `update.json` on launch and offer the newer build in-app (Settings also has *Check for
  updates*); the download opens Android's installer and the app updates in place.
  That in-place update needs every build signed with the same key: add the repository secrets
  `ANDROID_KEYSTORE_BASE64` (the `.jks` file, base64), `ANDROID_KEYSTORE_PASSWORD`,
  `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD` once. Make a key with
  `keytool -genkeypair -keystore magictrek.jks -storetype PKCS12 -alias magictrek -keyalg RSA -keysize 2048 -validity 36500`.
  Without the secrets the APK is signed with the runner's throwaway debug key: it installs, but
  the next build cannot update over it (the app says so and asks to uninstall first).
- **iOS**: `.github/workflows/ios-testflight.yml` archives `ios/Runner` and uploads to TestFlight
  on the same commits (`*b` archives without uploading; the workflow can also be run by hand).
  The version lives in `pubspec.yaml` (`version: 1.0.0+1`); after an upload the workflow writes
  the numbers it used back. TestFlight installs updates itself. Secrets: `APPLE_TEAM_ID`,
  `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`.
- **Every pull request**: `.github/workflows/flutter-ci.yml` runs the analyzer and tests, builds a
  debug APK (artifact) and an unsigned iOS build.

## Cards and images

The database is built from Scryfall, which has every printing of the set (showcase, extended-art
and promo versions included) with a high-resolution scan of each:

    tools/build-card-db.py                 # the sets in SETS: trk, trc, ttrk
    tools/build-card-db.py --sets trk,trc,ttrk,xyz   # add a set

It writes `assets/cards.json` and downloads one 672×936 JPG per printing into `assets/images/`
(cached in `.scryfall-cache/`, so re-runs only fetch what's new). Commit both. The app shows the
main printing of each card in the database and lets you browse all printings and the token sheet.

Cards that aren't on Scryfall yet (spoiled but not released) are listed in
`tools/card-overrides.json` with their rules text and use the mythicspoiler.com scan from `cards/`.
`.github/workflows/card-images.yml` keeps `cards/` current from https://mythicspoiler.com/trk/cards/
(daily, or Actions → Card images → Run workflow); once Scryfall lists a card, the override is
ignored automatically.

## Credits

Card images from mythicspoiler.com; card data from Scryfall. Magic: The Gathering is a trademark of
Wizards of the Coast; Star Trek of CBS Studios. Fan project, not affiliated with either.
