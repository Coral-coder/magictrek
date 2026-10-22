#!/usr/bin/env python3
"""Builds Packages/MagicTrekCore/Sources/CardKit/Resources/cards.json: one entry per card image in cards/, with the card's
rules data from Scryfall (sets trk = Star Trek, trc = Star Trek Commander) joined to it by name.
Cards Scryfall has no record for are filled in from tools/card-overrides.json.

    tools/build-card-db.py [--cache DIR]

Scryfall responses are cached in DIR (default .scryfall-cache, git-ignored) so re-runs are
offline. Prints what matched how and fails if any image is left without data.
"""
import argparse, difflib, json, os, re, sys, time, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CARDS_DIR = os.path.join(ROOT, "cards")
OUT = os.path.join(ROOT, "Packages", "MagicTrekCore", "Sources", "CardKit", "Resources", "cards.json")
OVERRIDES = os.path.join(ROOT, "tools", "card-overrides.json")
SETS = ["trk", "trc"]
UA = "magictrek-card-db/1.0 (https://github.com/coral-coder/magictrek)"
SKIP_FILES = {"mythicspoiler"}  # the site's logo, not a card


def get(url, cache_dir, key):
    path = os.path.join(cache_dir, key + ".json")
    if os.path.exists(path):
        return json.load(open(path))
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = json.load(r)
    os.makedirs(cache_dir, exist_ok=True)
    json.dump(data, open(path, "w"))
    time.sleep(0.12)  # Scryfall asks for <= 10 requests/s
    return data


def fetch_set(code, cache_dir):
    cards, page = [], 1
    url = ("https://api.scryfall.com/cards/search?order=set&unique=prints&include_extras=true"
           "&include_variations=true&q=" + urllib.parse.quote(f"set:{code}"))
    while url:
        data = get(url, cache_dir, f"{code}-page{page}")
        cards += data["data"]
        url = data.get("next_page")
        page += 1
    return cards


def fetch_named(name, cache_dir):
    url = "https://api.scryfall.com/cards/named?exact=" + urllib.parse.quote(name)
    return get(url, cache_dir, "named-" + norm(name))


def norm(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


def split_type_line(type_line):
    front = type_line.split(" // ")[0]
    left, _, right = front.partition(" — ")
    words = left.split()
    supertypes = [w for w in words if w in ("Legendary", "Basic", "Snow", "World")]
    types = [w for w in words if w not in supertypes]
    subtypes = right.split() if right else []
    return supertypes, types, subtypes


def station(oracle_text):
    """Spacecraft: the 'N+ | Flying, lifelink' line gives the Station threshold and what it has then."""
    m = re.search(r"^(\d+)\+\s*\|\s*(.*)$", oracle_text, re.M)
    if not m:
        return None, []
    return int(m.group(1)), [k.strip().lower() for k in m.group(2).split(",") if k.strip()]


def entry(file, c, variant):
    supertypes, types, subtypes = split_type_line(c["type_line"])
    threshold, station_keywords = station(c.get("oracle_text", ""))
    images = c.get("image_uris") or {}
    return {
        "id": file,
        "name": c["name"],
        "file": file + ".jpg",
        "set": c.get("set", ""),
        "collectorNumber": c.get("collector_number", ""),
        "rarity": c.get("rarity", "common"),
        "manaCost": c.get("mana_cost", ""),
        "manaValue": int(c.get("cmc", 0)),
        "colors": c.get("colors", []),
        "colorIdentity": c.get("color_identity", []),
        "typeLine": c["type_line"],
        "supertypes": supertypes,
        "types": types,
        "subtypes": subtypes,
        "oracleText": c.get("oracle_text", ""),
        "flavorText": c.get("flavor_text", ""),
        "keywords": c.get("keywords", []),
        "power": c.get("power"),
        "toughness": c.get("toughness"),
        "producedMana": c.get("produced_mana", []),
        "layout": c.get("layout", "normal"),
        "artist": c.get("artist", ""),
        "variant": variant,
        "imageLarge": images.get("large") or images.get("normal") or "",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default=os.path.join(ROOT, ".scryfall-cache"))
    args = ap.parse_args()

    scry = []
    for code in SETS:
        scry += fetch_set(code, args.cache)
    by_name = {}
    for c in scry:
        by_name.setdefault(norm(c["name"]), []).append(c)
    keys = list(by_name)
    overrides = {k: v for k, v in json.load(open(OVERRIDES)).items() if not k.startswith("_")}

    files = sorted(f[:-4] for f in os.listdir(CARDS_DIR) if f.endswith(".jpg") and f[:-4] not in SKIP_FILES)
    out, fuzzy, used = [], [], {}
    for f in files:
        if f in overrides:
            o = overrides[f]
            c = dict(fetch_named(o["base"], args.cache)) if "base" in o else {}
            c.update({k: v for k, v in o.items() if k != "base"})
            out.append(entry(f, c, variant=False))
            continue
        # The file name is the card name squashed, sometimes with a suffix: p (promo/alt art),
        # p2/p3 (further alternates), 1..4 (basic lands).
        candidates = [f, re.sub(r"\d+$", "", f), re.sub(r"p$", "", f), re.sub(r"p\d+$", "", f), re.sub(r"\d+p$", "", f)]
        key = next((k for k in candidates if k in by_name), None)
        if key is None:  # the site's own typos ("surveryors", "secruity")
            m = difflib.get_close_matches(f, keys, n=1, cutoff=0.8) or difflib.get_close_matches(candidates[2], keys, n=1, cutoff=0.8)
            if m:
                key = m[0]
                fuzzy.append((f, key))
        if key is None:
            print(f"ERROR: no data for cards/{f}.jpg; add it to tools/card-overrides.json", file=sys.stderr)
            sys.exit(1)
        # Several printings share a name; the first one taken is the main-set printing and
        # every image after it for the same name is a variant (alt art, promo, showcase).
        printings = by_name[key]
        n = used.get(key, 0)
        used[key] = n + 1
        c = printings[min(n, len(printings) - 1)]
        out.append(entry(f, c, variant=n > 0 or f != key and bool(re.search(r"p\d*$", f))))

    out.sort(key=lambda e: (e["set"] != "trk", e["set"], int(re.sub(r"\D", "", e["collectorNumber"]) or 0), e["id"]))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as fh:
        json.dump({"generated": time.strftime("%Y-%m-%d"), "cards": out}, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    distinct = len({e["name"] for e in out})
    print(f"{len(out)} images, {distinct} distinct cards, {len(fuzzy)} matched by fuzzy name:")
    for f, k in fuzzy:
        print(f"  {f} -> {k}")
    print(f"wrote {os.path.relpath(OUT, ROOT)}")


if __name__ == "__main__":
    main()
