# magictrek
Multiplayer Magic card game featuring Star Trek.

## TestFlight

`.github/workflows/ios-testflight.yml` (copied from Bond-touch-beyond) archives and uploads the
iOS app. Put `*u` in a commit subject on `main` to upload, `*b` to archive only, or run it by hand
from Actions. Signing uses Xcode cloud signing and never revokes certificates.

## Card images

`.github/workflows/card-images.yml` pulls every JPG from MythicSpoiler's Star Trek set listing
(https://mythicspoiler.com/trk/cards/) into `cards/` and commits whatever is new or changed. It
runs daily and from Actions → Card images → Run workflow. The same script works locally:

    .github/scripts/fetch-card-images.sh cards
