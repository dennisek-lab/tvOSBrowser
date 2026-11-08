#!/usr/bin/env python3
"""Erzeugt die erweiterten Werbeblocker-Regeln (Scriptlets und prozedurales CSS) für BrowserScriptletInjector.

Der WebKit-Content-Blocker kann diese Regeln nicht (tools/build_adblock_rules.py verwirft sie). Hier werden sie aus
denselben Listen gesammelt und als Domain->Regeln-Zuordnung ins App-Paket geschrieben. Die App spielt je Navigation
nur die Regeln der aktuellen Domain als JavaScript ein (document-start, alle Frames, Seitenwelt).

Aufruf (aus dem Repo-Wurzelverzeichnis):

    python3 tools/build_scriptlets.py              # Listen aus dem Cache von build_adblock_rules.py (tools/.adblock-cache)
    python3 tools/build_scriptlets.py --refresh    # Listen neu herunterladen
    python3 tools/build_scriptlets.py --no-register

Voraussetzung: node/npm. Die Bibliotheken @adguard/scriptlets und @adguard/extended-css (beide GPL-3.0) werden in
tools/vendor-download/scriptlets-npm installiert (nicht im Repo). Aus @adguard/scriptlets wird
dist/scriptlets.corelibs.json gelesen (jedes Scriptlet als eigenständige Funktion), der Konverter wandelt
uBO-Syntax (`##+js(...)`) ins AdGuard-Format. extended-css.min.js wird unverändert ins Paket kopiert.

Ausgabe: _Project/Browser/Scriptlets/
  scriptlets.json.z   raw deflate, JSON {version, names, fn, rules, css, hosts, generic, except, stats}
  extended-css.min.js unverändert aus @adguard/extended-css
  LICENSE-GPL-3.0.txt
  manifest.json       Zahlen und Gründe für verworfene Regeln
  (runtime.js im selben Ordner ist handgeschrieben und wird hier nicht angefasst)

Eigene Ergänzungen: tools/scriptlets-extra/eigene-regeln.txt (Regeln in uBO-Syntax) und
tools/scriptlets-extra/<uBO-Name>.js (eigene Scriptlets für uBO-Namen ohne AdGuard-Gegenstück).
"""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import zlib
from collections import Counter, OrderedDict

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import build_adblock_rules as abr  # noqa: E402  (Listen, Laden, Selektorprüfung)

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "_Project" / "Browser" / "Scriptlets"
VENDOR = pathlib.Path(__file__).resolve().parent / "vendor-download" / "scriptlets-npm"
SCRIPTLETS_VERSION = "2.5.1"
EXTCSS_VERSION = "2.3.0"

# Bedingungen der uBO-Vorverarbeitung (!#if ...). Die App kann Scriptlets, aber keine HTML-Filter, und
# meldet sich als Safari (Desktop-Kennung).
ENV = {"ext_ublock": True, "ext_ubol": False, "env_safari": True, "env_mobile": False, "env_chromium": False,
       "env_firefox": False, "env_edge": False, "env_mv3": False, "env_legacy": False, "cap_html_filtering": False,
       "cap_user_stylesheet": True, "cap_ipaddress": False, "adguard": False, "adguard_app_windows": False,
       "adguard_ext_safari": False, "false": False, "true": True}

# uBO-Scriptlets, die der AdGuard-Konverter nicht kennt, deren AdGuard-Gegenstück aber dieselben Argumente nimmt
UBO_FALLBACK = {
    "trusted-rpfr": "trusted-replace-fetch-response", "trusted-replace-fetch-response": "trusted-replace-fetch-response",
    "trusted-rpfr.js": "trusted-replace-fetch-response",
    "trusted-replace-xhr-response": "trusted-replace-xhr-response", "trusted-rpxr": "trusted-replace-xhr-response",
    "trusted-set": "trusted-set-constant", "trusted-set-constant": "trusted-set-constant",
    "trusted-set-attr": "trusted-set-attr", "trusted-click-element": "trusted-click-element",
    "trusted-set-cookie": "trusted-set-cookie", "trusted-set-local-storage-item": "trusted-set-local-storage-item",
    "trusted-set-session-storage-item": "trusted-set-session-storage-item",
    "trusted-suppress-native-method": "trusted-suppress-native-method",
    "trusted-replace-outbound-text": "trusted-replace-outbound-text", "trusted-prevent-xhr": "trusted-prevent-xhr",
}
# uBO replace-node-text (Knoten, Muster, Ersatz[, condition, Text]) -> AdGuard (Knoten, Textbedingung, Muster, Ersatz)
# eigene Scriptlets (uBO-only, von AdGuard nicht abgedeckt): tools/scriptlets-extra/<uBO-Name>.js
EXTRA_DIR = pathlib.Path(__file__).resolve().parent / "scriptlets-extra"
EXTRA = {f.stem: "\n".join(l for l in f.read_text().splitlines() if not l.startswith("//"))
         for f in sorted(EXTRA_DIR.glob("*.js"))}
UBO_RPNT = {"rpnt", "replace-node-text", "replace-node-text.js", "trusted-rpnt", "trusted-replace-node-text"}

# prozedurale uBO-Operatoren, die ExtendedCss nicht kennt
UNSUPPORTED_PROC = ("min-text-length", "others", "matches-media", "shadow", "if-not", "-abp-properties",
                    "matches-css-after", "spath")


class Stats:
    def __init__(self):
        self.ok = Counter()
        self.skip = Counter()


def preprocess(text):
    """uBO-Vorverarbeitung: Zeilen in nicht zutreffenden !#if-Blöcken entfernen."""
    stack = []  # (aktiv_vorher, bedingung)
    active = True
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("!#if "):
            cond = evaluate(s[5:])
            stack.append((active, cond))
            active = active and cond
            continue
        if s.startswith("!#else"):
            if stack:
                parent, cond = stack[-1]
                active = parent and not cond
            continue
        if s.startswith("!#endif"):
            if stack:
                active = stack.pop()[0]
            continue
        if active:
            yield s


def evaluate(expr):
    tokens = re.findall(r"[A-Za-z_][\w]*|&&|\|\||!|\(|\)", expr)
    out = []
    for t in tokens:
        out.append({"&&": " and ", "||": " or ", "!": " not ", "(": "(", ")": ")"}.get(t, str(ENV.get(t, False))))
    try:
        return bool(eval("".join(out), {"__builtins__": {}}))  # nur True/False/and/or/not
    except Exception:
        return False


def parse_domain_list(spec):
    """'a.com,~b.a.com,google.*' -> (positiv, negativ) oder None (Regex-Domain positiv)."""
    pos, neg = [], []
    for d in spec.split(","):
        d = d.strip()
        if not d:
            continue
        negated = d.startswith("~")
        if negated:
            d = d[1:]
        if d.startswith("/"):
            if negated:
                continue
            return None
        if d == "*":
            continue  # generisch
        entity = d.endswith(".*")
        core = d[:-2] if entity else d
        core = abr.to_ascii_domain(core)
        if core is None or not re.fullmatch(r"[a-z0-9.\-_]+", core):
            if negated:
                continue
            return None
        (neg if negated else pos).append(core + (".*" if entity else ""))
    return pos, neg


def split_ubo_args(body):
    """uBO-Argumente: Komma-getrennt, `\\,` maskiert, Anführungszeichen um ein Argument werden entfernt."""
    args, cur, i = [], "", 0
    while i < len(body):
        ch = body[i]
        if ch == "\\" and i + 1 < len(body) and body[i + 1] == ",":
            cur += ","
            i += 2
            continue
        if ch == ",":
            args.append(cur)
            cur = ""
            i += 1
            continue
        cur += ch
        i += 1
    args.append(cur)
    out = []
    for a in args:
        a = a.strip()
        if len(a) >= 2 and a[0] == a[-1] and a[0] in "'\"`":
            a = a[1:-1]
        out.append(a)
    return out


def ubo_fallback(selector):
    """Eigene Umsetzung für uBO-Scriptlets ohne Konverter-Unterstützung. Liefert {name, args} (AdGuard) oder None."""
    args = split_ubo_args(selector[4:-1])
    name = args[0]
    if name.endswith(".js"):
        name = name[:-3]
    rest = args[1:]
    # benannte Zusatzargumente (uBO: ..., condition, x, quitAfter, 1 ...)
    def named(pos):
        extra = rest[pos:]
        return {extra[k]: extra[k + 1] for k in range(0, len(extra) - 1, 2)}
    if name in UBO_RPNT and len(rest) >= 2:
        node, pattern = rest[0], rest[1]
        repl = rest[2] if len(rest) > 2 else ""
        cond = named(3).get("condition", pattern)
        return {"name": "trusted-replace-node-text", "args": [node, cond, pattern, repl]}
    if name == "trusted-replace-argument" and len(rest) >= 3:
        out = rest[:3]
        cond = named(3).get("condition")
        if cond:
            out.append(cond)
        return {"name": "trusted-replace-argument", "args": out}
    if name in EXTRA:
        return {"name": name, "args": rest}
    target = UBO_FALLBACK.get(name)
    if target is None:
        return None
    limit = {"trusted-replace-fetch-response": 3, "trusted-replace-xhr-response": 3, "trusted-replace-outbound-text": 3,
             "trusted-suppress-native-method": 3, "trusted-prevent-xhr": 2}.get(target)
    if limit is not None:
        rest = rest[:limit]
    return {"name": target, "args": rest}


PROC_RE = re.compile(r":(-?[a-z][a-z\-]*)\(")


def convert_procedural(sel):
    """uBO/ABP-Prozedural -> ExtendedCss-Syntax. Liefert (text, pfad) oder (None, grund)."""
    path = None
    m = re.match(r"^:matches-path\((.+?)\)\s*", sel)
    if m:
        path = m.group(1)
        sel = sel[m.end():]
        if not sel:
            return None, "matches-path ohne selektor"
    if ":matches-path(" in sel:
        return None, "matches-path innen"
    for op in UNSUPPORTED_PROC:
        if ":" + op + "(" in sel:
            return None, "operator :" + op
    sel = re.sub(r":watch-attr\([^)]*\)", "", sel)
    sel = sel.replace(":matches-prop(", ":matches-property(").replace(":if(", ":has(")
    style = None
    m = re.search(r":style\((.*)\)$", sel)
    if m:
        style = m.group(1)
        sel = sel[:m.start()]
        if "{" in style or "}" in style:
            return None, "style mit klammern"
    if not sel.strip():
        return None, "leer"
    text = sel + (" { " + style + " }" if style is not None else "")
    return text, path


class Builder:
    def __init__(self, corelibs):
        self.stats = Stats()
        self.fn_by_alias = {}
        self.fn_names, self.fn_code, self.fn_index = [], [], {}
        for entry in corelibs["scriptlets"]:
            for n in entry["names"]:
                self.fn_by_alias.setdefault(n, entry)
        for name, code in EXTRA.items():
            self.fn_by_alias.setdefault(name, {"names": [name], "scriptlet": code})
        self.pending = []      # (domains, exc, ruletext-for-node, origin)
        self.rules = OrderedDict()  # key -> [fn, args]
        self.css = OrderedDict()    # key -> [text, proc, path]
        self.hosts = {}
        self.exc = {}
        self.generic_s = set()
        self.generic_exc_keys = set()
        self.exc_keys = []     # (host, kind, key)  kind 's'/'c', key '*' = alle

    def add_line(self, line):
        if not line or line[0] == "!" or line.startswith("["):
            return
        m = abr.COSMETIC_RE.match(line)
        if not m or line.startswith("|") or "/" in line.split("#")[0]:
            return
        domains, exc, kind, sel = m.groups()
        exc = bool(exc)
        if kind == "%":
            if sel.startswith("//scriptlet("):
                self.pending.append((domains, exc, "#%#" + sel, "adg"))
            else:
                self.stats.skip["adguard-js (kein scriptlet)"] += 1
            return
        if not kind and sel.startswith("+js("):
            if sel == "+js()":
                if exc:
                    parsed = parse_domain_list(domains)
                    for d in (parsed[0] if parsed else []):
                        self.exc_keys.append((d, "s", "*"))
                    self.stats.ok["scriptlet-ausnahme"] += 1
                return
            self.pending.append((domains, exc, "##" + sel, "ubo"))
            return
        if kind == "$" and not re.search(r"\{.*\}\s*$", sel):
            self.pending.append((domains, exc, "#$#" + sel, "abp"))
            return
        if not kind and sel.startswith("^"):
            return  # HTML-Filter: nicht möglich
        self.add_cosmetic(domains, exc, kind, sel)

    def add_cosmetic(self, domains, exc, kind, sel):
        parsed = parse_domain_list(domains) if domains else ([], [])
        if parsed is None:
            self.stats.skip["kosmetik regex-domain"] += 1
            return
        pos, neg = parsed
        plain = not kind and abr.selector_ok(sel)
        if plain:
            simple_domains = all(not d.endswith(".*") for d in pos)
            if not pos or (simple_domains and not neg) or (exc and simple_domains):
                return  # erledigt der WebKit-Content-Blocker (build_adblock_rules.py)
            text, path, proc = sel, None, 0
        elif kind == "$" or kind == "$?":
            m = re.match(r"^(.*?)\s*\{(.*)\}\s*$", sel)
            if not m:
                self.stats.skip["css-injektion ungueltig"] += 1
                return
            text, path, proc = m.group(1) + " { " + m.group(2) + " }", None, 1
        else:
            text, path = convert_procedural(sel)
            if text is None:
                self.stats.skip["prozedural " + path] += 1
                return
            proc = 1
        if not pos and not exc:
            self.stats.skip["kosmetik generisch prozedural"] += 1
            return
        key = json.dumps([text, proc, path])
        if exc:
            for d in pos:
                self.exc_keys.append((d, "c", key))
            if not pos:
                self.generic_exc_keys.add(("c", key))
            self.stats.ok["kosmetik-ausnahme"] += 1
            return
        if key not in self.css:
            self.css[key] = [text, proc, path] if path else [text, proc]
        for d in pos:
            self.hosts.setdefault(d, {"s": set(), "c": set()})["c"].add(key)
        for d in neg:
            self.exc_keys.append((d, "c", key))
        self.stats.ok["kosmetik-prozedural" if proc else "kosmetik-css (platzhalter/~)"] += 1

    def resolve_scriptlets(self):
        texts = []
        for domains, exc, rule, origin in self.pending:
            texts.append(rule)
        res = subprocess.run(["node", str(pathlib.Path(__file__).resolve().parent / "scriptlets_convert.mjs"), str(VENDOR)],
                             input=json.dumps(texts).encode(), capture_output=True, check=True)
        results = json.loads(res.stdout)
        for i, ((domains, exc, rule, origin), r) in enumerate(zip(self.pending, results)):
            if not r["ok"] and origin == "ubo":
                fb = ubo_fallback(rule[2:])
                if fb is not None and fb["name"] in self.fn_by_alias:
                    results[i] = {"ok": True, "calls": [fb], "fallback": True}
        for (domains, exc, rule, origin), r in zip(self.pending, results):
            if not r["ok"]:
                name = rule[6:].split(",")[0].strip().rstrip(")") if origin == "ubo" else origin
                self.stats.skip["scriptlet " + name + " (" + r["error"].split(":")[0] + ")"] += 1
                continue
            parsed = parse_domain_list(domains) if domains else ([], [])
            if parsed is None:
                self.stats.skip["scriptlet regex-domain"] += 1
                continue
            pos, neg = parsed
            for call in r["calls"]:
                entry = self.fn_by_alias.get(call["name"])
                if entry is None:
                    self.stats.skip["scriptlet unbekannt " + call["name"]] += 1
                    continue
                canonical = entry["names"][0]
                if canonical not in self.fn_index:
                    self.fn_index[canonical] = len(self.fn_names)
                    self.fn_names.append(canonical)
                    self.fn_code.append(entry["scriptlet"])
                fidx = self.fn_index[canonical]
                key = json.dumps([fidx, call["args"]])
                if exc:
                    for d in pos:
                        self.exc_keys.append((d, "s", key))
                    if not pos:
                        self.generic_exc_keys.add(("s", key))
                    self.stats.ok["scriptlet-ausnahme"] += 1
                    continue
                if key not in self.rules:
                    self.rules[key] = [fidx, call["args"]]
                if not pos:
                    self.generic_s.add(key)
                for d in pos:
                    self.hosts.setdefault(d, {"s": set(), "c": set()})["s"].add(key)
                for d in neg:
                    self.exc_keys.append((d, "s", key))
                self.stats.ok["scriptlet" + (" (eigene zuordnung)" if r.get("fallback") else "")] += 1

    def build(self):
        # global abgeschaltete Regeln entfernen
        for kind, key in self.generic_exc_keys:
            table = self.rules if kind == "s" else self.css
            table.pop(key, None)
            self.generic_s.discard(key)
        rule_idx = {k: i for i, k in enumerate(self.rules)}
        css_idx = {k: i for i, k in enumerate(self.css)}
        hosts = {}
        for d in sorted(self.hosts):
            e = self.hosts[d]
            s = sorted(rule_idx[k] for k in e["s"] if k in rule_idx)
            c = sorted(css_idx[k] for k in e["c"] if k in css_idx)
            if s or c:
                hosts[d] = {k: v for k, v in (("s", s), ("c", c)) if v}
        exc = {}
        for d, kind, key in self.exc_keys:
            if key == "*":
                idx = -1
            else:
                idx = (rule_idx if kind == "s" else css_idx).get(key)
                if idx is None:
                    continue
            exc.setdefault(d, {}).setdefault(kind, set()).add(idx)
        exc = {d: {k: sorted(v) for k, v in e.items()} for d, e in sorted(exc.items())}
        return {
            "names": self.fn_names,
            "fn": self.fn_code,
            "rules": list(self.rules.values()),
            "css": list(self.css.values()),
            "hosts": hosts,
            "generic": {"s": sorted(rule_idx[k] for k in self.generic_s if k in rule_idx)},
            "except": exc,
        }


def ensure_vendor():
    marker = VENDOR / "node_modules" / "@adguard" / "scriptlets" / "package.json"
    ec = VENDOR / "node_modules" / "@adguard" / "extended-css" / "package.json"
    ok = False
    if marker.exists() and ec.exists():
        ok = (json.loads(marker.read_text()).get("version") == SCRIPTLETS_VERSION and
              json.loads(ec.read_text()).get("version") == EXTCSS_VERSION)
    if not ok:
        VENDOR.mkdir(parents=True, exist_ok=True)
        (VENDOR / "package.json").write_text('{"name":"tvbrowser-scriptlets-vendor","private":true}\n')
        print(f"  npm install @adguard/scriptlets@{SCRIPTLETS_VERSION} @adguard/extended-css@{EXTCSS_VERSION}", file=sys.stderr)
        subprocess.check_call(["npm", "install", "--ignore-scripts", "--no-audit", "--no-fund", "--silent",
                               f"@adguard/scriptlets@{SCRIPTLETS_VERSION}", f"@adguard/extended-css@{EXTCSS_VERSION}"],
                              cwd=VENDOR)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--refresh", action="store_true")
    ap.add_argument("--no-register", action="store_true")
    args = ap.parse_args()

    ensure_vendor()
    sl_dir = VENDOR / "node_modules" / "@adguard" / "scriptlets"
    ec_dir = VENDOR / "node_modules" / "@adguard" / "extended-css"
    corelibs = json.loads((sl_dir / "dist" / "scriptlets.corelibs.json").read_text())
    b = Builder(corelibs)
    for list_id, fmt, urls in abr.LISTS:
        if fmt != "abp":
            continue
        for url in urls:
            for line in preprocess(abr.fetch(list_id, url, args.refresh)):
                b.add_line(line)
    for line in preprocess((EXTRA_DIR / "eigene-regeln.txt").read_text()):
        b.add_line(line)
    b.resolve_scriptlets()
    data = b.build()
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"), sort_keys=False).encode("utf-8")
    version = hashlib.sha256(payload).hexdigest()[:12]
    data["version"] = version
    data["library"] = {"scriptlets": corelibs.get("version", SCRIPTLETS_VERSION), "extendedCss": EXTCSS_VERSION}
    data["stats"] = {"converted": dict(b.stats.ok), "skipped": dict(b.stats.skip.most_common())}
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    packed = comp.compress(payload) + comp.flush()
    (OUT_DIR / "scriptlets.json.z").write_bytes(packed)
    shutil.copyfile(ec_dir / "dist" / "extended-css.min.js", OUT_DIR / "extended-css.min.js")
    shutil.copyfile(sl_dir / "LICENSE", OUT_DIR / "LICENSE-GPL-3.0.txt")
    stats = {"version": version, "library": data["library"], "rules": len(data["rules"]), "css": len(data["css"]),
             "hosts": len(data["hosts"]), "functions": len(data["fn"]), "generic": len(data["generic"]["s"]),
             "jsonBytes": len(payload), "packedBytes": len(packed), **data["stats"]}
    (OUT_DIR / "manifest.json").write_text(json.dumps(stats, indent=1, ensure_ascii=False))
    print(f"Scriptlet-Regeln {len(data['rules'])}, CSS-Regeln {len(data['css'])}, Hosts {len(data['hosts'])}, "
          f"Funktionen {len(data['fn'])}, generisch {len(data['generic']['s'])}", file=sys.stderr)
    print(f"JSON {len(payload) / 1e6:.2f} MB, gepackt {len(packed) / 1e6:.2f} MB", file=sys.stderr)
    print("Uebernommen:", dict(b.stats.ok), file=sys.stderr)
    print("Uebersprungen (haeufigste):", file=sys.stderr)
    for reason, n in b.stats.skip.most_common(25):
        print(f"  {n:6d}  {reason}", file=sys.stderr)
    if not args.no_register:
        subprocess.check_call([sys.executable, str(ROOT / "tools" / "add_resource.py"), "Scriptlets"])


if __name__ == "__main__":
    main()
