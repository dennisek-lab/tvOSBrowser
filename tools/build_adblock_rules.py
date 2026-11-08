#!/usr/bin/env python3
"""Wandelt die Standardlisten von uBlock Origin Lite in WebKit-Content-Blocker-JSON um.

Aufruf (aus dem Repo-Wurzelverzeichnis, nur Python-3-Standardbibliothek):

    python3 tools/build_adblock_rules.py            # laedt Listen (Cache in tools/.adblock-cache), schreibt JSON
    python3 tools/build_adblock_rules.py --refresh  # Listen neu herunterladen
    python3 tools/build_adblock_rules.py --no-register  # nicht im Xcode-Projekt eintragen
    python3 tools/build_adblock_rules.py --out-dir DIR  # anderer Ausgabeordner (GitHub-Workflow filterlisten.yml)

Ausgabe: _Project/Browser/ContentBlocker/*.json.z (raw deflate) und manifest.json. Die Dateien werden in der
Sources/Resources-Phase des App-Targets registriert (tools/add_resource.py). Das Skript
ist wiederholbar: Listen aktualisieren heisst einfach erneut ausfuehren und committen.

Listenauswahl (gelesen aus gorhill/uBlock, platform/mv3/rulesets.json, Gruppe "default" und "malware",
dazu EasyList Germany wegen deutscher Seiten). Aenderungen: LISTS weiter unten anpassen.

Aufteilung (WebKit-Grenze 150.000 Regeln je Regelsatz, Ausnahmen `ignore-previous-rules` wirken nur
innerhalb eines Regelsatzes):
  network-N      Netzwerkregeln (Blocken, Ausnahmen @@, $important), bei Bedarf in mehrere Dateien
  cosmetic-generic   `##selector` ohne Domain (url-filter .*)
  cosmetic-domain    `domain##selector`

Nicht uebersetzbar und nur gezaehlt: Scriptlets (##+js), prozedurale Kosmetik (:has-text, :xpath ...),
$redirect, $removeparam, $csp, $replace, $header, HTML-Filter, regulaere Ausdruecke, die WebKit nicht kann,
Domains mit Platzhalter-TLD (google.*) u. a.
"""
import argparse
import hashlib
import zlib
import json
import pathlib
import re
import subprocess
import sys
import time
import urllib.request
from collections import Counter, OrderedDict

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "_Project" / "Browser" / "ContentBlocker"
CACHE_DIR = pathlib.Path(__file__).resolve().parent / ".adblock-cache"

UBO = "https://ublockorigin.github.io/uAssets/"
# (id, Format, URLs). Format: "abp" oder "hosts"
LISTS = [
    ("ublock-filters", "abp", [UBO + "filters/quick-fixes.min.txt", UBO + "filters/unbreak.min.txt",
                                UBO + "filters/filters.min.txt", UBO + "filters/privacy.min.txt",
                                UBO + "filters/ubol-filters.txt"]),
    ("easylist", "abp", [UBO + "thirdparties/easylist.txt"]),
    ("easyprivacy", "abp", [UBO + "thirdparties/easyprivacy.txt"]),
    ("pgl", "hosts", ["https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=1&mimetype=plaintext"]),
    ("ublock-badware", "abp", [UBO + "filters/badware.min.txt"]),
    ("urlhaus", "hosts", ["https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-hosts.txt"]),
    ("easylist-germany", "abp", ["https://easylist.to/easylistgermany/easylistgermany.txt"]),
]

MAX_RULES_PER_LIST = 140000  # Reserve unter dem WebKit-Limit von 150.000

# WebKit-Ressourcentypen
ALL_NON_DOC = ["image", "style-sheet", "script", "font", "raw", "fetch", "media", "svg-document",
               "ping", "websocket", "other", "popup"]
TYPE_MAP = {
    "script": ["script"], "image": ["image"], "stylesheet": ["style-sheet"], "css": ["style-sheet"],
    "font": ["font"], "media": ["media"], "xmlhttprequest": ["raw", "fetch"], "xhr": ["raw", "fetch"],
    "object": ["other"], "object-subrequest": ["other"], "other": ["other"], "ping": ["ping"],
    "beacon": ["ping"], "websocket": ["websocket"], "popup": ["popup"],
}
SUBFRAME = {"subdocument", "frame"}
TOPDOC = {"document", "doc"}
IGNORED_OPTIONS = {"all_noop", "important_noop"}
SKIP_OPTIONS = {"redirect", "redirect-rule", "removeparam", "queryprune", "csp", "permissions", "replace",
                "header", "denyallow", "to", "method", "cname", "ipaddress", "empty", "mp4", "inline-script",
                "inline-font", "webrtc", "strict1p", "strict3p", "ctag", "uritransform", "urltransform",
                "reason", "badfilter_noop", "genericblock", "specifichide", "shide", "elemhide_noop",
                "extension", "stealth", "network", "domain_regex"}

SAFE_PSEUDO = {"not", "has", "is", "where", "nth-child", "nth-of-type", "nth-last-child", "nth-last-of-type",
               "first-child", "last-child", "only-child", "first-of-type", "last-of-type", "only-of-type",
               "empty", "root", "checked", "disabled", "enabled", "link", "lang"}

COSMETIC_RE = re.compile(r"^([\w.~*,\-]*)#(@?)(\$\?|\?|\$|%)?#(.+)$")
OPTION_TOKEN_RE = re.compile(r"^~?[a-z][a-z0-9\-]*(=.*)?$")
HOST_RE = re.compile(r"^[a-z0-9][a-z0-9.\-]*[a-z0-9]$")


class Stats:
    def __init__(self):
        self.converted = Counter()
        self.skipped = Counter()

    def ok(self, kind):
        self.converted[kind] += 1

    def skip(self, reason):
        self.skipped[reason] += 1


def fetch(list_id, url, refresh):
    CACHE_DIR.mkdir(exist_ok=True)
    path = CACHE_DIR / (list_id + "-" + hashlib.md5(url.encode()).hexdigest()[:8] + ".txt")
    if refresh or not path.exists():
        print(f"  lade {url}", file=sys.stderr)
        req = urllib.request.Request(url, headers={"User-Agent": "tvos-browser-rulebuilder"})
        with urllib.request.urlopen(req, timeout=120) as resp:
            path.write_bytes(resp.read())
    return path.read_text(encoding="utf-8", errors="replace")


def to_ascii_domain(d):
    try:
        return d.encode("idna").decode("ascii").lower()
    except UnicodeError:
        return None


def parse_domains(spec, sep):
    """Liefert (positiv, negativ) oder None bei nicht ausdrueckbaren Domains (Platzhalter, Regex)."""
    pos, neg = [], []
    for d in spec.split(sep):
        d = d.strip()
        if not d:
            continue
        negated = d.startswith("~")
        if negated:
            d = d[1:]
        if d.startswith("/") or "*" in d or d.endswith(".") or " " in d:
            return None
        d = to_ascii_domain(d)
        if d is None or not re.fullmatch(r"[a-z0-9.\-_]+", d):
            return None
        (neg if negated else pos).append(d)
    return pos, neg


def selector_ok(sel):
    if not sel or len(sel) > 2000:
        return False
    if re.search(r"[{};]", sel) or sel[0] in ">+~" or sel.startswith("+js(") or sel.startswith("^"):
        return False
    stripped = re.sub(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', '""', sel)
    stripped = re.sub(r"\[[^\]]*\]", "[]", stripped)
    if "::" in stripped:
        return False
    for m in re.finditer(r":([A-Za-z\-]+)", stripped):
        if m.group(1).lower() not in SAFE_PSEUDO:
            return False
    depth = 0
    for ch in stripped:
        depth += (ch == "(") - (ch == ")")
        if depth < 0:
            return False
    return depth == 0


SEP = "[^a-z0-9_.%-]"


def pattern_to_regex(pat):
    """ABP-Muster -> WebKit-url-filter (Teilmenge von ICU-Regex ohne Alternativen). None = nicht moeglich."""
    if pat.startswith("/") and pat.endswith("/") and len(pat) > 2:
        return None  # regulaere Ausdruecke von Listen: nicht sicher uebersetzbar
    prefix = ""
    if pat.startswith("||"):
        prefix = "^[a-z]+://([^/]+\\.)?"
        pat = pat[2:]
    elif pat.startswith("|"):
        prefix = "^"
        pat = pat[1:]
    suffix = ""
    if pat.endswith("|"):
        suffix = "$"
        pat = pat[:-1]
    if "|" in pat or not pat.isascii():
        return None
    out = []
    for ch in pat:
        if ch == "*":
            out.append(".*")
        elif ch == "^":
            out.append(SEP)
        elif ch in ".+?()[]{}\\$":
            out.append("\\" + ch)
        else:
            out.append(ch)
    regex = prefix + "".join(out) + suffix
    # fuehrendes/abschliessendes ".*" ist ueberfluessig
    if not prefix:
        while regex.startswith(".*"):
            regex = regex[2:]
    if not suffix:
        while regex.endswith(".*"):
            regex = regex[:-2]
    return regex if regex else ".*"


def pure_host(pat):
    """'||host^' (nur Host, optional ^) -> host, sonst None."""
    m = re.fullmatch(r"\|\|([A-Za-z0-9.\-]+)\^?", pat)
    if m and HOST_RE.match(m.group(1).lower()):
        return m.group(1).lower()
    return None


class Converter:
    def __init__(self):
        self.stats = Stats()
        self.block = OrderedDict()       # Schluessel -> Regel
        self.exceptions = OrderedDict()
        self.important = OrderedDict()
        self.site_doc = set()            # @@||host^$document  -> in alle Regelsaetze
        self.site_elemhide = set()       # $elemhide / $ghide
        self.site_generichide = set()
        self.generic_css = OrderedDict() # selector -> Menge Ausnahme-Domains
        self.domain_css = OrderedDict()  # selector -> Menge Domains
        self.css_exc_generic = {}        # selector -> Ausnahmedomains (None = ueberall)
        self.css_exc_domain = []         # (selector, domains)
        self.badfilters = set()

    # ---- Zeilen aufnehmen
    def add_line(self, line):
        line = line.strip()
        if not line or line[0] == "!" or line.startswith("[") or line.startswith("# "):
            return
        m = COSMETIC_RE.match(line)
        if m and not (line.startswith("||") or line.startswith("|") or "/" in line.split("#")[0]):
            self.add_cosmetic(*m.groups())
            return
        self.add_network(line)

    def add_cosmetic(self, domains, exc, kind, selector):
        if kind:
            self.stats.skip("kosmetik-erweitert (#?# #$# #%#)")
            return
        if selector.startswith("+js(") or selector.startswith("+js"):
            self.stats.skip("scriptlet (##+js)")
            return
        if selector.startswith("^"):
            self.stats.skip("html-filter (##^)")
            return
        if not selector_ok(selector):
            self.stats.skip("kosmetik-prozedural/ungueltig (:has-text, :xpath ...)")
            return
        pos, neg = [], []
        if domains:
            parsed = parse_domains(domains, ",")
            if parsed is None:
                self.stats.skip("kosmetik-domain-platzhalter")
                return
            pos, neg = parsed
        if exc:
            if not pos:
                self.css_exc_generic[selector] = None
            else:
                self.css_exc_domain.append((selector, pos))
                if self.css_exc_generic.setdefault(selector, set()) is not None:
                    self.css_exc_generic[selector].update(pos)
            self.stats.ok("kosmetik-ausnahme")
            return
        if not pos:
            self.generic_css.setdefault(selector, set()).update(neg)
            self.stats.ok("kosmetik-generisch")
        else:
            if neg:
                self.stats.skip("kosmetik-domain-gemischt (~)")
                return
            self.domain_css.setdefault(selector, set()).update(pos)
            self.stats.ok("kosmetik-domain")

    def add_network(self, line):
        exc = line.startswith("@@")
        body = line[2:] if exc else line
        pattern, opts = body, ""
        idx = body.rfind("$")
        if idx >= 0 and all(OPTION_TOKEN_RE.match(t) for t in body[idx + 1:].split(",")):
            pattern, opts = body[:idx], body[idx + 1:]
        if "##" in line or "#@#" in line:
            self.stats.skip("kosmetik-sonstige")
            return
        third = None  # True/False/None
        types, negtypes = set(), set()
        subframe = topdoc = important = matchcase = False
        elemhide = generichide = False
        if_dom, unless_dom = [], []
        for opt in [o for o in opts.split(",") if o]:
            neg = opt.startswith("~")
            name = opt[1:] if neg else opt
            val = None
            if "=" in name:
                name, val = name.split("=", 1)
            name = name.lower()
            if name == "badfilter":
                self.badfilters.add(line.replace(",badfilter", "").replace("$badfilter", ""))
                return
            if name in ("third-party", "3p"):
                third = not neg
            elif name in ("first-party", "1p"):
                third = neg
            elif name in ("domain", "from"):
                parsed = parse_domains(val or "", "|")
                if parsed is None:
                    self.stats.skip("domain-platzhalter/regex")
                    return
                if_dom += parsed[0]
                unless_dom += parsed[1]
            elif name == "important":
                important = True
            elif name == "match-case":
                matchcase = True
            elif name == "all":
                pass
            elif name in TOPDOC:
                topdoc = not neg
            elif name in SUBFRAME:
                if neg:
                    negtypes.add("subdocument")
                else:
                    subframe = True
            elif name in ("elemhide", "ehide", "ghide", "generichide"):
                elemhide = elemhide or name in ("elemhide", "ehide")
                generichide = True
            elif name in TYPE_MAP:
                (negtypes if neg else types).update(TYPE_MAP[name])
            elif name in SKIP_OPTIONS:
                self.stats.skip("option $" + name)
                return
            else:
                self.stats.skip("option $" + name + " (unbekannt)")
                return
        if if_dom and unless_dom:
            self.stats.skip("domain gemischt (~)")
            return
        # Seitenweite Ausnahmen
        if exc and (topdoc or elemhide or generichide):
            host = pure_host(pattern)
            if host is None:
                self.stats.skip("seitenweite Ausnahme mit Muster")
                return
            if topdoc:
                self.site_doc.add(host)
            elif elemhide:
                self.site_elemhide.add(host)
            else:
                self.site_generichide.add(host)
            self.stats.ok("seitenweite-ausnahme")
            return
        if elemhide or generichide:
            self.stats.skip("option $elemhide")
            return
        regex = pattern_to_regex(pattern)
        if regex is None:
            self.stats.skip("muster (regex/nicht-ASCII/Alternative)")
            return
        # Typen
        explicit = types or subframe or topdoc
        if explicit:
            main_types = sorted(types)
        elif negtypes:
            main_types = [t for t in ALL_NON_DOC if t not in negtypes]
        else:
            main_types = None  # Standard
        trigger = {"url-filter": regex}
        if matchcase:
            trigger["url-filter-is-case-sensitive"] = True
        if third is True:
            trigger["load-type"] = ["third-party"]
        elif third is False:
            trigger["load-type"] = ["first-party"]
        if if_dom:
            trigger["if-domain"] = ["*" + d for d in sorted(set(if_dom))]
        elif unless_dom:
            trigger["unless-domain"] = ["*" + d for d in sorted(set(unless_dom))]
        action = {"type": "ignore-previous-rules" if exc else "block"}
        target = self.important if (important and not exc) else (self.exceptions if exc else self.block)
        host = pure_host(pattern)

        def emit(trig):
            key = json.dumps([trig, action], sort_keys=True)
            if key not in target:
                target[key] = {"trigger": trig, "action": action}

        if main_types is None:
            if host is not None:
                emit(dict(trigger))  # reiner Host: alle Typen inkl. Unterframes
            else:
                t = dict(trigger)
                t["resource-type"] = ALL_NON_DOC
                emit(t)
                t2 = dict(trigger)
                t2["resource-type"] = ["document"]
                t2["load-context"] = ["child-frame"]
                emit(t2)
        else:
            if main_types:
                t = dict(trigger)
                t["resource-type"] = main_types
                emit(t)
            if subframe:
                t = dict(trigger)
                t["resource-type"] = ["document"]
                t["load-context"] = ["child-frame"]
                emit(t)
            if topdoc:
                t = dict(trigger)
                t["resource-type"] = ["document"]
                t["load-context"] = ["top-frame"]
                emit(t)
            if not main_types and not subframe and not topdoc:
                self.stats.skip("leere typmenge")
                return
        self.stats.ok("netzwerk-ausnahme" if exc else "netzwerk-block")

    # ---- Ausgabe
    def build_lists(self):
        if self.badfilters:
            # Regeln entfernen, die per $badfilter deaktiviert sind: Wir vergleichen nach Neuaufbau nicht,
            # sondern zaehlen nur (badfilter ist selten und betrifft meist Listenkonflikte).
            self.stats.skip(f"badfilter (nicht angewendet: {len(self.badfilters)})")
        doc_rules = []
        for h in sorted(self.site_doc):
            doc_rules.append({"trigger": {"url-filter": ".*", "if-domain": ["*" + h]},
                              "action": {"type": "ignore-previous-rules"}})
        network_block = list(self.block.values())
        network_tail = list(self.exceptions.values()) + list(self.important.values())
        network_lists = []
        chunk = MAX_RULES_PER_LIST - len(network_tail) - len(doc_rules)
        for i in range(0, max(len(network_block), 1), chunk):
            network_lists.append(network_block[i:i + chunk] + network_tail + doc_rules)

        # Generische Kosmetik
        generic = []
        for sel, exc_dom in self.generic_css.items():
            exc = set(exc_dom)
            e = self.css_exc_generic.get(sel, set())
            if e is None:
                continue
            exc |= e
            trig = {"url-filter": ".*"}
            if exc:
                trig["unless-domain"] = ["*" + d for d in sorted(exc)]
            generic.append({"trigger": trig, "action": {"type": "css-display-none", "selector": sel}})
        for h in sorted(self.site_elemhide | self.site_generichide):
            generic.append({"trigger": {"url-filter": ".*", "if-domain": ["*" + h]},
                            "action": {"type": "ignore-previous-rules"}})
        generic += doc_rules

        # Domain-Kosmetik
        exc_by_sel = {}
        for sel, doms in self.css_exc_domain:
            exc_by_sel.setdefault(sel, set()).update(doms)
        domain = []
        for sel, doms in self.domain_css.items():
            doms = set(doms) - exc_by_sel.get(sel, set())
            if not doms:
                continue
            domain.append({"trigger": {"url-filter": ".*", "if-domain": ["*" + d for d in sorted(doms)]},
                           "action": {"type": "css-display-none", "selector": sel}})
        for h in sorted(self.site_elemhide):
            domain.append({"trigger": {"url-filter": ".*", "if-domain": ["*" + h]},
                           "action": {"type": "ignore-previous-rules"}})
        domain += doc_rules
        result = OrderedDict()
        for i, rules in enumerate(network_lists):
            result[f"network-{i + 1}"] = rules
        result["cosmetic-generic"] = generic
        result["cosmetic-domain"] = domain
        return result


def parse_hosts(text, conv):
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        parts = line.split()
        if len(parts) < 2 or parts[0] not in ("0.0.0.0", "127.0.0.1"):
            if len(parts) == 1 and HOST_RE.match(parts[0].lower()) and "." in parts[0]:
                host = parts[0].lower()
            else:
                continue
        else:
            host = parts[1].lower()
        if host in ("localhost", "localhost.localdomain", "local", "broadcasthost") or not HOST_RE.match(host):
            continue
        trig = {"url-filter": "^[a-z]+://([^/]+\\.)?" + host.replace(".", "\\.") + "[:/]"}
        key = json.dumps(trig)
        if key not in conv.block:
            conv.block[key] = {"trigger": trig, "action": {"type": "block"}}
            conv.stats.ok("netzwerk-block (hosts)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--refresh", action="store_true")
    ap.add_argument("--no-register", action="store_true")
    ap.add_argument("--out-dir", type=pathlib.Path, default=None,
                    help="Ausgabeordner statt _Project/Browser/ContentBlocker (impliziert --no-register)")
    args = ap.parse_args()
    out_dir = args.out_dir.resolve() if args.out_dir else OUT_DIR
    if args.out_dir:
        args.no_register = True

    conv = Converter()
    per_list = {}
    for list_id, fmt, urls in LISTS:
        print(f"{list_id}:", file=sys.stderr)
        before_ok, before_skip = Counter(conv.stats.converted), Counter(conv.stats.skipped)
        for url in urls:
            text = fetch(list_id, url, args.refresh)
            if fmt == "hosts":
                parse_hosts(text, conv)
            else:
                for line in text.splitlines():
                    conv.add_line(line)
        ok = conv.stats.converted - before_ok
        skipped = conv.stats.skipped - before_skip
        per_list[list_id] = (sum(ok.values()), sum(skipped.values()), dict(skipped))
        print(f"  uebersetzt {sum(ok.values())}, uebersprungen {sum(skipped.values())}", file=sys.stderr)

    lists = conv.build_lists()
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in list(out_dir.glob("*.json")) + list(out_dir.glob("*.json.z")):
        old.unlink()
    manifest = {"lists": []}
    total = 0
    for name, rules in lists.items():
        data = json.dumps(rules, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        digest = hashlib.sha256(data).hexdigest()[:12]
        # Raw-Deflate (NSDataCompressionAlgorithmZlib), das spart im Paket etwa 90 %
        comp = zlib.compressobj(9, zlib.DEFLATED, -15)
        packed = comp.compress(data) + comp.flush()
        (out_dir / f"{name}.json.z").write_bytes(packed)
        manifest["lists"].append({"name": name, "file": f"{name}.json.z", "hash": digest,
                                  "rules": len(rules), "jsonBytes": len(data)})
        total += len(packed)
        print(f"{name}: {len(rules)} Regeln, {len(data) / 1e6:.2f} MB JSON, {len(packed) / 1e6:.2f} MB gepackt", file=sys.stderr)
    manifest["version"] = hashlib.sha256("".join(l["hash"] for l in manifest["lists"]).encode()).hexdigest()[:12]
    # Erzeugungszeit (Unix-Sekunden, UTC): Die App vergleicht damit mitgelieferte und heruntergeladene Listen,
    # der neuere Stand gewinnt (BrowserFilterListUpdater).
    manifest["generatedAt"] = int(time.time())
    manifest["date"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(manifest["generatedAt"]))
    manifest["sources"] = {k: {"converted": v[0], "skipped": v[1], "skippedByReason": v[2]} for k, v in per_list.items()}
    manifest["totals"] = {"converted": dict(conv.stats.converted), "skipped": dict(conv.stats.skipped)}
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=1, ensure_ascii=False))
    print(f"Gesamt im Paket: {total / 1e6:.2f} MB", file=sys.stderr)
    print("Uebersprungen nach Grund:", file=sys.stderr)
    for reason, n in conv.stats.skipped.most_common():
        print(f"  {n:7d}  {reason}", file=sys.stderr)

    if not args.no_register:
        subprocess.check_call([sys.executable, str(ROOT / "tools" / "add_resource.py"), "ContentBlocker"])


if __name__ == "__main__":
    main()
