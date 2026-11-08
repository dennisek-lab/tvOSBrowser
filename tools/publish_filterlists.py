#!/usr/bin/env python3
"""Stellt die Filterlisten für die automatische Aktualisierung in der App zusammen (GitHub-Workflow filterlisten.yml).

Aufruf (nach build_adblock_rules.py und build_scriptlets.py mit --out-dir):

    python3 tools/publish_filterlists.py --contentblocker OUT/contentblocker --scriptlets OUT/scriptlets \\
        --out OUT/publish [--previous alt/manifest.json]

Ergebnis in --out:
  manifest.json                 Gesamtmanifest, das die App lädt (Format siehe unten)
  network-1-<sha>.json.z …      Regelsätze, Dateiname mit SHA-256-Präfix (inhaltsadressiert: ein neues Manifest
  scriptlets-<sha>.json.z       zeigt nie auf eine alte Datei gleichen Namens, auch nicht über einen CDN-Cache)
  LICENSE-GPL-3.0.txt           Lizenz der Scriptlet-Bibliothek (lädt die App nicht)
  keep.txt                      Dateien, die im Release bleiben sollen (neu + vorheriger Stand)

Ausgabe auf stdout: `changed=true|false` (für $GITHUB_OUTPUT). Unverändert heißt: Regelsätze und Scriptlets haben
denselben Inhaltsstand wie --previous; dann braucht der Workflow nichts hochzuladen.

Manifest:
  format         Formatversion dieses Manifests und der Dateien
  minAppFormat   Mindest-Formatversion der App (BrowserFilterListAppFormat in BrowserFilterListUpdater.m).
                 Erhöhen, wenn ältere Apps die Dateien nicht mehr verstehen (z. B. neue Scriptlet-Laufzeit nötig).
  version        lesbarer Gesamtstand (Datum + Inhaltsstände)
  generatedAt    Unix-Sekunden (UTC), date als ISO-Text
  contentBlocker {version, generatedAt, date, lists: [{name, file, hash, sha256, bytes, rules, jsonBytes}]}
                 hash = SHA-256-Präfix des entpackten JSON (Kennung im WKContentRuleListStore),
                 sha256/bytes = der gepackten Datei, wie sie geladen wird
  scriptlets     {version, generatedAt, date, library, file, sha256, bytes}
"""
import argparse
import hashlib
import json
import pathlib
import shutil
import sys
import time

FORMAT = 1
MIN_APP_FORMAT = 1


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def publish_file(src, out, stem):
    digest = sha256(src)
    name = f"{stem}-{digest[:16]}.json.z"
    shutil.copyfile(src, out / name)
    return name, digest, src.stat().st_size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--contentblocker", type=pathlib.Path, required=True)
    ap.add_argument("--scriptlets", type=pathlib.Path, required=True)
    ap.add_argument("--out", type=pathlib.Path, required=True)
    ap.add_argument("--previous", type=pathlib.Path, default=None, help="bisher veröffentlichtes manifest.json")
    args = ap.parse_args()

    out = args.out
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    cb = json.loads((args.contentblocker / "manifest.json").read_text())
    sl = json.loads((args.scriptlets / "manifest.json").read_text())
    for name, m in (("contentblocker", cb), ("scriptlets", sl)):
        if "generatedAt" not in m or "version" not in m:
            sys.exit(f"{name}/manifest.json ohne generatedAt/version (Build-Skripte zu alt?)")

    lists = []
    for entry in cb["lists"]:
        file, digest, size = publish_file(args.contentblocker / entry["file"], out, entry["name"])
        lists.append({"name": entry["name"], "file": file, "hash": entry["hash"], "sha256": digest,
                      "bytes": size, "rules": entry["rules"], "jsonBytes": entry["jsonBytes"]})
    if not lists:
        sys.exit("keine Regelsätze")
    sl_file, sl_digest, sl_size = publish_file(args.scriptlets / "scriptlets.json.z", out, "scriptlets")
    shutil.copyfile(args.scriptlets / "LICENSE-GPL-3.0.txt", out / "LICENSE-GPL-3.0.txt")

    now = int(time.time())
    date = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    manifest = {
        "format": FORMAT,
        "minAppFormat": MIN_APP_FORMAT,
        "version": f"{time.strftime('%Y%m%d-%H%M', time.gmtime(now))}-{cb['version']}-{sl['version']}",
        "generatedAt": now,
        "date": date,
        "contentBlocker": {"version": cb["version"], "generatedAt": cb["generatedAt"], "date": cb.get("date", ""),
                           "lists": lists},
        "scriptlets": {"version": sl["version"], "generatedAt": sl["generatedAt"], "date": sl.get("date", ""),
                       "library": sl.get("library", {}), "file": sl_file, "sha256": sl_digest, "bytes": sl_size},
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + "\n")

    keep = {"manifest.json", "LICENSE-GPL-3.0.txt", sl_file} | {l["file"] for l in lists}
    changed = True
    if args.previous and args.previous.exists():
        try:
            prev = json.loads(args.previous.read_text())
            keep |= {l["file"] for l in prev.get("contentBlocker", {}).get("lists", [])}
            if prev.get("scriptlets", {}).get("file"):
                keep.add(prev["scriptlets"]["file"])
            changed = not (prev.get("contentBlocker", {}).get("version") == cb["version"] and
                           prev.get("scriptlets", {}).get("version") == sl["version"] and
                           prev.get("minAppFormat") == MIN_APP_FORMAT and prev.get("format") == FORMAT)
        except (ValueError, KeyError, AttributeError) as e:
            print(f"vorheriges Manifest unlesbar ({e}), veröffentliche neu", file=sys.stderr)
    (out / "keep.txt").write_text("\n".join(sorted(keep)) + "\n")

    total = sum(l["bytes"] for l in lists) + sl_size
    print(f"Manifest {manifest['version']}: {len(lists)} Regelsätze, Scriptlets {sl['version']}, "
          f"{total / 1e6:.2f} MB, geändert: {changed}", file=sys.stderr)
    print(f"changed={'true' if changed else 'false'}")


if __name__ == "__main__":
    main()
