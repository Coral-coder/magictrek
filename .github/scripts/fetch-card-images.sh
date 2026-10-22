#!/usr/bin/env bash
# Downloads every JPG listed in a directory index (by default MythicSpoiler's Star Trek set,
# https://mythicspoiler.com/trk/cards/) into a folder. Files already there are only fetched
# again when the server has a newer copy, so repeated runs are cheap and the site isn't hammered.
#
#   .github/scripts/fetch-card-images.sh [destination] [index URL]
#
# Prints the counts and, when GITHUB_OUTPUT is set, writes added=<n> updated=<n> total=<n> for
# the workflow. Exits non-zero if the index can't be read or any image fails to download.
set -euo pipefail

dest="${1:-cards}"
url="${2:-https://mythicspoiler.com/trk/cards/}"
url="${url%/}/"
agent="magictrek-card-images (+https://github.com/${GITHUB_REPOSITORY:-coral-coder/magictrek})"
jobs="${FETCH_JOBS:-6}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Reading $url"
curl -fsSL --retry 3 --retry-delay 5 -A "$agent" "$url" -o "$tmp/index.html"

# Plain file names only: a link with a slash or query string is a folder, a sort link or
# another page, not an image in this folder.
grep -oiE 'href="[^"/?#]+\.jpe?g"' "$tmp/index.html" \
  | sed -E 's/^href="//; s/"$//' | sort -u > "$tmp/names.txt"
count=$(wc -l < "$tmp/names.txt")
if [ "$count" -eq 0 ]; then echo "No .jpg links found in $url" >&2; exit 1; fi
echo "$count images listed"

mkdir -p "$dest"
# Snapshot of what is there now, to tell added from updated afterwards. Content hashes, not
# times: the site's CDN hands out different Last-Modified dates for the same bytes, so a few
# files get fetched again each run without actually changing.
snapshot() { (cd "$1" && find . -maxdepth 1 -type f -iname '*.jp*g' -printf '%f\n' | sort | xargs -r -d '\n' md5sum) | awk '{print $2, $1}'; }
snapshot "$dest" > "$tmp/before.txt"

# One curl per file: -z only downloads when the server's copy is newer than ours, -R keeps
# the server's modification time so the next -z works. Failures are collected, not fatal
# per file, so one broken link doesn't stop the rest.
fetch() {
  name="$1"; dest="$2"; url="$3"; agent="$4"
  target="$dest/$name"
  args=(-fsSL --retry 3 --retry-delay 5 -A "$agent" -R -o "$target")
  [ -f "$target" ] && args+=(-z "$target")
  if ! curl "${args[@]}" "$url$name"; then
    echo "FAILED $name" >&2
    return 1
  fi
}
export -f fetch
status=0
xargs -a "$tmp/names.txt" -P "$jobs" -I{} bash -c 'fetch "$@"' _ {} "$dest" "$url" "$agent" || status=1

snapshot "$dest" > "$tmp/after.txt"
added=$(comm -13 <(cut -d' ' -f1 "$tmp/before.txt") <(cut -d' ' -f1 "$tmp/after.txt") | wc -l)
# In both snapshots but with a different hash.
updated=$(comm -12 "$tmp/before.txt" "$tmp/after.txt" | cut -d' ' -f1 \
  | comm -13 - <(comm -12 <(cut -d' ' -f1 "$tmp/before.txt") <(cut -d' ' -f1 "$tmp/after.txt")) | wc -l)
total=$(wc -l < "$tmp/after.txt")

echo "Added $added, updated $updated, $total images in $dest"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "added=$added"; echo "updated=$updated"; echo "total=$total"; } >> "$GITHUB_OUTPUT"
fi
if [ "$status" -ne 0 ]; then echo "Some images failed to download" >&2; fi
exit "$status"
