#!/usr/bin/env python3
"""Builds the card database the app ships: assets/cards.json plus one high-resolution image per
printing in assets/images/.

The source of truth is Scryfall: every printing of every set in SETS (the Star Trek set, its
Commander decks and its tokens), with Scryfall's "large" scan (672x936) downloaded for each.
Cards Scryfall doesn't list yet come from tools/card-overrides.json with the mythicspoiler.com
scan in cards/ as their image.

    tools/build-card-db.py [--sets trk,trc,ttrk] [--size large|normal] [--cache DIR]
    tools/build-card-db.py --tokens-only    # add the EXTRA_TOKENS scans to the existing database

To add a set later, add its code to --sets (or SETS below) and re-run; everything is cached in
DIR (default .scryfall-cache, git-ignored) so re-runs are quick and offline-friendly.
"""
import argparse, json, os, re, sys, time, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CARDS_DIR = os.path.join(ROOT, "cards")
OUT = os.path.join(ROOT, "assets", "cards.json")
IMAGES = os.path.join(ROOT, "assets", "images")
OVERRIDES = os.path.join(ROOT, "tools", "card-overrides.json")
SETS = ["trk", "trc", "ttrk"]

# Tokens the cards make that the Star Trek token set doesn't print. Each comes from another set's
# printing whose rules text matches exactly, so the scan shows what the token does.
EXTRA_TOKENS = {
    "Treasure": "{T}, Sacrifice this token: Add one mana of any color.",
    "Clue": "{2}, Sacrifice this token: Draw a card.",
    "Food": "{2}, {T}, Sacrifice this token: You gain 3 life.",
}
UA = "magictrek-card-db/2.0 (https://github.com/coral-coder/magictrek)"


def get_json(url, cache_dir, key):
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
        try:
            data = get_json(url, cache_dir, f"{code}-page{page}")
        except urllib.error.HTTPError as e:
            if e.code == 404 and page == 1:
                print(f"WARNING: set {code} has no cards on Scryfall yet", file=sys.stderr)
                return []
            raise
        cards += data["data"]
        url = data.get("next_page")
        page += 1
    return cards


def fetch_named(name, cache_dir):
    return get_json("https://api.scryfall.com/cards/named?exact=" + urllib.parse.quote(name), cache_dir, "named-" + norm(name))


def download(url, path):
    if os.path.exists(path) and os.path.getsize(path) > 1000:
        return False
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r, open(path + ".part", "wb") as f:
        f.write(r.read())
    os.replace(path + ".part", path)
    time.sleep(0.1)
    return True


def norm(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


def split_type_line(type_line):
    front = type_line.split(" // ")[0]
    left, _, right = front.partition(" — ")
    words = left.split()
    supertypes = [w for w in words if w in ("Legendary", "Basic", "Snow", "World", "Token")]
    types = [w for w in words if w not in supertypes]
    subtypes = right.split() if right else []
    return supertypes, types, subtypes


def image_uris(c):
    if "image_uris" in c:
        return c["image_uris"]
    faces = c.get("card_faces") or []
    return faces[0].get("image_uris", {}) if faces else {}


def entry(card_id, c, image_file, variant, is_token):
    supertypes, types, subtypes = split_type_line(c["type_line"])
    uris = image_uris(c)
    return {
        "id": card_id,
        "name": c["name"],
        "file": image_file,
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
        "token": is_token,
        "scryfallId": c.get("id", ""),
        "imageLarge": uris.get("large") or uris.get("normal") or "",
        "frame": c.get("frame_effects", []) + c.get("promo_types", []),
    }


def same_text(a, b):
    """Token rules text, compared loosely: older printings say "this artifact" or "~"."""
    t = lambda x: re.sub(r"(this (artifact|token)|~)", "~", (x or "").strip().lower())
    return t(a) == t(b)


def extra_tokens(have, size, cache_dir):
    """Entries for EXTRA_TOKENS not already in the database, newest matching printing first."""
    out = []
    for name, text in EXTRA_TOKENS.items():
        if any(e["token"] and e["name"] == name for e in have):
            continue
        url = ("https://api.scryfall.com/cards/search?order=released&dir=desc&unique=prints&include_extras=true&q="
               + urllib.parse.quote(f'!"{name}" t:token game:paper -is:universesbeyond'))
        found = None
        for c in get_json(url, cache_dir, "token-" + norm(name))["data"]:
            # A plain printing: no Secret Lair, promo or full-art versions.
            plain = c.get("set_type") not in ("box", "promo", "memorabilia", "funny") and not c.get("full_art")
            if plain and same_text(c.get("oracle_text"), text) and image_uris(c):
                found = c
                break
        if found is None:
            print(f"WARNING: no {name} token printing with that text", file=sys.stderr)
            continue
        uris = image_uris(found)
        card_id = f"tok-{norm(name)}"
        download(uris.get(size) or uris.get("large") or uris.get("normal"), os.path.join(IMAGES, f"{card_id}.jpg"))
        e = entry(card_id, found, f"images/{card_id}.jpg", False, True)
        e["set"] = "tok"
        out.append(e)
    return out


def tokens_only(args):
    db = json.load(open(OUT))
    added = extra_tokens(db["cards"], args.size, args.cache)
    db["cards"] += added
    with open(OUT, "w") as fh:
        json.dump(db, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    print(f"added {len(added)} tokens: {', '.join(e['name'] + ' (' + e['collectorNumber'] + ')' for e in added)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets", default=",".join(SETS), help="comma-separated Scryfall set codes")
    ap.add_argument("--size", default="large", choices=["large", "normal", "png"])
    ap.add_argument("--cache", default=os.path.join(ROOT, ".scryfall-cache"))
    ap.add_argument("--tokens-only", action="store_true", help="only add EXTRA_TOKENS to the existing database")
    args = ap.parse_args()
    if args.tokens_only:
        return tokens_only(args)
    sets = [s.strip().lower() for s in args.sets.split(",") if s.strip()]
    os.makedirs(IMAGES, exist_ok=True)

    out, downloaded = [], 0
    # The first (lowest collector number, non-promo) printing of each name is the main one.
    seen_names = {}
    for code in sets:
        cards = fetch_set(code, args.cache)
        cards.sort(key=lambda c: (bool(c.get("promo")), int(re.sub(r"\D", "", c.get("collector_number", "0")) or 0), c.get("collector_number", "")))
        for c in cards:
            num = re.sub(r"[^A-Za-z0-9]", "", c.get("collector_number", ""))
            card_id = f"{code}-{num}"
            is_token = c.get("layout") == "token" or c.get("set_type") == "token" or "Token" in c["type_line"]
            uris = image_uris(c)
            url = uris.get(args.size) or uris.get("large") or uris.get("normal")
            image_file = f"images/{card_id}.jpg"
            if url:
                if download(url, os.path.join(IMAGES, f"{card_id}.jpg")):
                    downloaded += 1
            else:
                print(f"WARNING: no image for {card_id} {c['name']}", file=sys.stderr)
                image_file = ""
            key = (is_token, norm(c["name"]))
            variant = key in seen_names
            seen_names.setdefault(key, card_id)
            out.append(entry(card_id, c, image_file, variant, is_token))

    # Cards Scryfall doesn't have: rules from an override, image from the mythicspoiler scan.
    overrides = {k: v for k, v in json.load(open(OVERRIDES)).items() if not k.startswith("_")}
    for stem, o in overrides.items():
        c = dict(fetch_named(o["base"], args.cache)) if "base" in o else {}
        use_scryfall_image = bool(o.get("useScryfallImage"))
        c.update({k: v for k, v in o.items() if k not in ("base", "useScryfallImage")})
        if "set" not in c:
            continue
        number = re.sub(r"[^A-Za-z0-9]", "", c.get("collector_number") or "")
        card_id = f"{c['set']}-{number or stem}"
        if any(e["id"] == card_id or (e["set"] == c["set"] and norm(e["name"]) == norm(c["name"])) for e in out):
            continue  # Scryfall lists it in this set now; the override is no longer needed
        uris = image_uris(c) if use_scryfall_image else {}
        url = uris.get(args.size) or uris.get("large") or uris.get("normal")
        if url:
            dst = f"{card_id}.jpg"
            if download(url, os.path.join(IMAGES, dst)):
                downloaded += 1
        else:
            src = os.path.join(CARDS_DIR, stem + ".jpg")
            if not os.path.exists(src):
                print(f"WARNING: no scan cards/{stem}.jpg for override {c['name']}", file=sys.stderr)
                continue
            dst = f"ms-{stem}.jpg"
            with open(src, "rb") as f, open(os.path.join(IMAGES, dst), "wb") as g:
                g.write(f.read())
        c.pop("image_uris", None)
        key = (False, norm(c["name"]))
        variant = key in seen_names
        seen_names.setdefault(key, card_id)
        out.append(entry(card_id, c, f"images/{dst}", variant, False))

    out += extra_tokens(out, args.size, args.cache)

    # Drop images that no longer belong to any card.
    wanted = {e["file"].split("/")[-1] for e in out if e["file"]}
    removed = 0
    for f in os.listdir(IMAGES):
        if f.endswith(".jpg") and f not in wanted:
            os.remove(os.path.join(IMAGES, f))
            removed += 1

    out.sort(key=lambda e: (sets.index(e["set"]) if e["set"] in sets else len(sets), int(re.sub(r"\D", "", e["collectorNumber"]) or 0), e["id"]))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as fh:
        json.dump({"generated": time.strftime("%Y-%m-%d"), "sets": sets, "cards": out}, fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    distinct = len({(e["token"], e["name"]) for e in out})
    size = sum(os.path.getsize(os.path.join(IMAGES, f)) for f in os.listdir(IMAGES)) / 1e6
    print(f"{len(out)} printings, {distinct} distinct cards ({sum(1 for e in out if e['token'])} tokens), {downloaded} images downloaded, {removed} stale removed, {size:.0f} MB of images")
    print(f"wrote {os.path.relpath(OUT, ROOT)}")


if __name__ == "__main__":
    main()
