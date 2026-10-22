# MagicTrek
Multiplayer Magic: The Gathering–style card game for iOS featuring the Star Trek set, with an
LCARS interface. Play against the computer, pass-and-play on one phone, or online over iCloud
with push notifications when it's your move.

## Layout

| Path | What |
| --- | --- |
| `cards/` | The 351 card scans (JPG) pulled from mythicspoiler.com by the Card images workflow. |
| `tools/build-card-db.py` | Joins those images with Scryfall's rules data into `cards.json`. Run it after new cards arrive. |
| `Packages/MagicTrekCore` | Swift package, builds and tests on Linux and macOS: `CardKit` (database + rules-text parser) and `GameEngine` (deterministic rules, combat, triggers, computer player, starter decks). |
| `MagicTrek/` | The SwiftUI app: LCARS theme, menus, card database browser, deck builder, the game table, CloudKit matches. |
| `project.yml` | XcodeGen definition; `xcodegen generate` produces `MagicTrek.xcodeproj`. |
| `MagicTrek/CloudKit/schema.ckdb` | The CloudKit record types for online play. |

## Building

    brew install xcodegen
    xcodegen generate
    open MagicTrek.xcodeproj

The rules engine on its own: `cd Packages/MagicTrekCore && swift test`. Two developer tools:
`swift run CardTool` prints how much of the set the parser covers (and `swift run CardTool "Picard"`
shows one card's abilities); `REPLAY=1 swift run SimTool 7` plays a bot-vs-bot game and checks
that replaying its actions gives the same state.

## How the game works

- A game is its seed plus an ordered list of `GameAction`s. Replaying them on any device gives the
  same `GameState`, which is what keeps two phones in sync and what the solo save file stores.
- Rules text is parsed into a fixed vocabulary of keywords, triggers, static abilities and effects.
  Cards whose text the parser doesn't fully cover still play with their printed stats and whatever
  abilities did parse; the card database screen says what's missing for each card. Starter decks
  only use fully implemented cards.
- The set's mechanics: Station (Spacecraft become creatures with enough charge counters), Sagas,
  Landfall, Explore, Surveil, Ward, Kicker, Cycling, Beam me up, Assimilate and Discover.
- The computer player is heuristic: lands by color need, best castable spell, safe attacks, blocks
  that trade well or prevent lethal.

## Online play (CloudKit) – one-time setup

Online matches live in the app's public CloudKit database. Xcode's automatic signing creates the
container (`iCloud.<bundle id>`), but the schema must be deployed once:

1. Open [CloudKit Console](https://icloud.developer.apple.com) → the MagicTrek container → Schema.
2. Import `MagicTrek/CloudKit/schema.ckdb` (or create the `Match` and `MatchAction` record types with
   the fields and indexes it lists), then **Deploy Schema Changes to Production**. TestFlight builds
   use the production environment.
3. Under Security Roles, give `_icloud` **write** on `Match` (a guest joins by updating the host's
   record). The schema file already grants this.
4. Push notifications: the `aps-environment` entitlement is set; nothing else to configure, CloudKit
   sends the pushes.

Players need to be signed in to iCloud. A host creates a match and shares its 6-letter code; the guest
joins with it; from then on each move is a `MatchAction` record and a subscription pushes it to the
other device with a "your move" notification.

## TestFlight

`.github/workflows/ios-testflight.yml` (copied from Bond-touch-beyond) archives and uploads the
iOS app. Put `*u` in a commit subject on `main` to upload, `*b` to archive only, or run it by hand
from Actions. Signing uses Xcode cloud signing and never revokes certificates. The project is
generated from `project.yml` on the runner. `.github/workflows/ios-build.yml` builds for the
simulator and runs the engine tests on every pull request.

## Card images

`.github/workflows/card-images.yml` pulls every JPG from MythicSpoiler's Star Trek set listing
(https://mythicspoiler.com/trk/cards/) into `cards/` and commits whatever is new or changed. It
runs daily and from Actions → Card images → Run workflow. The same script works locally:

    .github/scripts/fetch-card-images.sh cards

After new images land, run `tools/build-card-db.py` and commit the updated `cards.json`.

## Credits

Card images from mythicspoiler.com; card data from Scryfall. Magic: The Gathering is a trademark of
Wizards of the Coast; Star Trek of CBS Studios. Fan project, not affiliated with either.
