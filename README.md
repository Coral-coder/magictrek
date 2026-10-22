# magictrek
Multiplayer Magic card game featuring Star Trek.

## TestFlight

`.github/workflows/ios-testflight.yml` (from Dev_deploy_setup) archives and uploads the iOS app.
Put `*u` in a commit subject on `main` to upload, `*b` to archive only, or run it by hand from
Actions. App-specific setup goes in `.github/scripts/pre-build.sh`. Signing uses Xcode cloud
signing and never revokes certificates.
