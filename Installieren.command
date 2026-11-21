#!/bin/bash
# tvOS Browser: aktualisieren, bauen und auf das Apple TV aufspielen (Doppelklick im Finder).
#
# Optionen (für Tests im Terminal):
#   --nur-bauen        ohne Gerät für 'generic/platform=tvOS' bauen, unsigniert, nichts installieren
#   --geraete          nur die gefundenen Apple TVs auflisten
#   --kein-pull        git pull überspringen
#   --starten / --nicht-starten   App nach dem Aufspielen ohne Rückfrage starten bzw. nicht starten
#   --debug            Debug statt Release bauen
# Umgebungsvariable UDID=<Kennung> wählt ein Gerät ohne Rückfrage.

set -u
cd "$(dirname "$0")" || exit 1
ROOT="$(pwd)"

PROJEKT="_Project/Browser.xcodeproj"
SCHEMA="Browser"
KONFIG="Release"
# Bundle-ID und Team aus _Project/Signing.xcconfig bzw. der eigenen _Project/Signing.local.xcconfig (gewinnt).
xcconfig_wert() {
  local wert="" datei
  for datei in "$ROOT/_Project/Signing.xcconfig" "$ROOT/_Project/Signing.local.xcconfig"; do
    [ -f "$datei" ] || continue
    local zeile
    zeile=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$datei" | tail -1 | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$zeile" ] && wert="$zeile"
  done
  printf '%s' "$wert"
}
BUNDLE_ID="$(xcconfig_wert BROWSER_BUNDLE_ID)"
TEAM_ID="$(xcconfig_wert DEVELOPMENT_TEAM)"
BUILD_DIR="$ROOT/build"
LOG="$ROOT/build.log"

NUR_BAUEN=0; NUR_GERAETE=0; PULL=1; STARTEN=""
for a in "$@"; do
  case "$a" in
    --nur-bauen) NUR_BAUEN=1 ;;
    --geraete) NUR_GERAETE=1 ;;
    --kein-pull) PULL=0 ;;
    --starten) STARTEN=ja ;;
    --nicht-starten) STARTEN=nein ;;
    --debug) KONFIG="Debug" ;;
    *) echo "Unbekannte Option: $a"; exit 2 ;;
  esac
done

fett() { printf '\033[1m%s\033[0m\n' "$*"; }
fehler() { printf '\033[31mFehler: %s\033[0m\n' "$*"; }
hinweis() { printf '\033[33m%s\033[0m\n' "$*"; }

ende() {
  local code=${1:-0}
  echo
  if [ -t 0 ] && [ -z "${KEIN_WARTEN:-}" ] && [ "$NUR_BAUEN" = 0 ] && [ "$NUR_GERAETE" = 0 ]; then
    read -r -p "Zum Beenden Eingabetaste drücken. " _
  fi
  exit "$code"
}

fett "tvOS Browser installieren"
echo

# ---------- 1. Aktualisieren ----------
if [ "$PULL" = 1 ] && [ -d .git ] && [ -n "$(git remote 2>/dev/null)" ]; then
  fett "1/5 Aktualisieren (git pull)"
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    hinweis "Es gibt lokale, nicht eingecheckte Änderungen. Ich aktualisiere trotzdem, falls das ohne Konflikt geht."
  fi
  if ! ausgabe=$(git pull --ff-only 2>&1); then
    echo "$ausgabe"
    fehler "Aktualisieren hat nicht geklappt."
    case "$ausgabe" in
      *"Could not resolve host"*|*"unable to access"*|*"Failed to connect"*) echo "Wahrscheinlich keine Internetverbindung oder GitHub nicht erreichbar." ;;
      *"Authentication"*|*"Permission denied"*|*"could not read Username"*) echo "Anmeldung bei GitHub fehlt oder ist abgelaufen (das Repo ist privat). Im Terminal einmal 'gh auth login' bzw. 'git pull' ausführen." ;;
      *"Not possible to fast-forward"*|*"divergent"*|*"diverged"*) echo "Lokaler und entfernter Stand weichen voneinander ab. Bitte im Terminal 'git status' prüfen." ;;
      *"overwritten"*|*"Aborting"*) echo "Lokale Änderungen würden überschrieben. Erst einchecken oder zurücksetzen." ;;
      *"no tracking information"*|*"no upstream"*) echo "Für diesen Zweig ist kein Gegenstück auf GitHub eingetragen." ;;
    esac
    hinweis "Ich baue mit dem vorhandenen Stand weiter."
  else
    echo "$ausgabe" | tail -3
  fi
  echo
elif [ "$PULL" = 1 ]; then
  echo "1/5 Aktualisieren: übersprungen (kein Git-Remote vorhanden)."
  echo
fi

# ---------- 2. Xcode ----------
fett "2/5 Xcode prüfen"
if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  fehler "xcodebuild ist nicht nutzbar."
  echo "Xcode installieren (App Store oder developer.apple.com), einmal starten und die Lizenz bestätigen."
  echo "Falls Xcode installiert ist: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  ende 1
fi
xcodebuild -version | head -2
if ! xcrun --sdk appletvos --show-sdk-path >/dev/null 2>&1; then
  fehler "Das tvOS-SDK fehlt."
  echo "In Xcode unter Einstellungen > Komponenten die Plattform tvOS laden."
  ende 1
fi
if ! xcrun devicectl --version >/dev/null 2>&1; then
  fehler "'xcrun devicectl' fehlt. Dafür braucht es Xcode 15 oder neuer."
  ende 1
fi
if [ ! -d "$PROJEKT" ]; then fehler "Projekt $PROJEKT nicht gefunden."; ende 1; fi

# Geteiltes Schema vorhanden?
SCHEMA_DATEI="$PROJEKT/xcshareddata/xcschemes/$SCHEMA.xcscheme"
if [ ! -f "$SCHEMA_DATEI" ]; then
  hinweis "Geteiltes Schema '$SCHEMA' fehlt, lege es an."
  mkdir -p "$(dirname "$SCHEMA_DATEI")"
  if ! python3 - "$PROJEKT/project.pbxproj" "$SCHEMA_DATEI" <<'PY'
import re, sys
pbx = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'(\w{24}) /\* Browser \*/ = \{\s*isa = PBXNativeTarget;', pbx)
if not m:
    sys.exit("Target 'Browser' nicht im Projekt gefunden")
tid = m.group(1)
ref = f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{tid}" BuildableName = "Browser.app" BlueprintName = "Browser" ReferencedContainer = "container:Browser.xcodeproj"></BuildableReference>'
xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
'''
open(sys.argv[2], "w", encoding="utf-8").write(xml)
PY
  then
    fehler "Schema konnte nicht angelegt werden. In Xcode unter Product > Scheme > Manage Schemes 'Shared' ankreuzen."
    ende 1
  fi
fi
echo

# ---------- Hilfsskripte (nur, wenn vorhanden) ----------
for h in tools/fetch_whisper_model.sh tools/build_whisper.sh; do
  if [ -f "$h" ]; then
    fett "Hilfsskript $h"
    if ! bash "$h"; then
      hinweis "$h meldete einen Fehler. Ich baue trotzdem weiter; die Spracherkennung fehlt dann evtl. in der App."
    fi
    echo
  fi
done

bauen_args=(-project "$PROJEKT" -scheme "$SCHEMA" -configuration "$KONFIG" -derivedDataPath "$BUILD_DIR")

# ---------- Nur-Bauen-Modus (ohne Gerät) ----------
if [ "$NUR_BAUEN" = 1 ]; then
  fett "Bauen ($KONFIG, ohne Signatur, ohne Gerät)"
  if xcodebuild "${bauen_args[@]}" -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build >"$LOG" 2>&1; then
    tail -3 "$LOG"
    echo "Fertig. Protokoll: $LOG"
    exit 0
  else
    grep -E "error:" "$LOG" | sort -u | head -10
    fehler "Bauen fehlgeschlagen. Protokoll: $LOG"
    exit 1
  fi
fi

# ---------- 3. Gerät suchen ----------
fett "3/5 Apple TV suchen"
JSON="$(mktemp -t tvdevices)"
trap 'rm -f "$JSON"' EXIT
if ! xcrun devicectl list devices --json-output "$JSON" -q >/dev/null 2>&1 || [ ! -s "$JSON" ]; then
  fehler "Die Geräteliste ließ sich nicht lesen."
  echo "Probiere im Terminal: xcrun devicectl list devices"
  ende 1
fi
# Ausgabe: UDID<TAB>Name<TAB>Modell<TAB>Verbindung
LISTE="$(python3 - "$JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for x in d["result"]["devices"]:
    hw, dp, cp = x.get("hardwareProperties", {}), x.get("deviceProperties", {}), x.get("connectionProperties", {})
    if hw.get("platform") != "tvOS" or hw.get("reality") == "simulated":
        continue
    if cp.get("pairingState") != "paired":
        continue
    print("\t".join([hw.get("udid", x["identifier"]), dp.get("name", "?"), hw.get("marketingName", hw.get("productType", "")), cp.get("tunnelState", "?")]))
PY
)"
if [ -z "$LISTE" ]; then
  fehler "Kein gekoppeltes Apple TV gefunden."
  echo "- Apple TV und Mac im selben WLAN, Apple TV eingeschaltet (nicht im Ruhezustand)."
  echo "- Am Apple TV: Einstellungen > Fernbedienungen und Geräte > Fernbedienungs-App und Geräte offen lassen."
  echo "- Einmalig koppeln: Device Hub (Xcode) > File > Pair Nearby Device…"
  ende 1
fi
ANZAHL=$(printf '%s\n' "$LISTE" | wc -l | tr -d ' ')
if [ "$NUR_GERAETE" = 1 ]; then printf '%s\n' "$LISTE"; exit 0; fi

if [ -n "${UDID:-}" ]; then
  GERAET_ZEILE="$(printf '%s\n' "$LISTE" | awk -F'\t' -v u="$UDID" '$1==u')"
  [ -n "$GERAET_ZEILE" ] || { fehler "Gerät $UDID nicht in der Liste."; ende 1; }
elif [ "$ANZAHL" = 1 ]; then
  GERAET_ZEILE="$LISTE"
else
  echo "Mehrere Apple TVs gefunden:"
  i=1
  while IFS=$'\t' read -r u n m t; do echo "  $i) $n ($m) [$t]"; i=$((i+1)); done <<<"$LISTE"
  if [ ! -t 0 ]; then fehler "Mehrere Geräte, aber keine Eingabe möglich. UDID=<Kennung> setzen."; ende 1; fi
  while :; do
    read -r -p "Nummer wählen: " wahl
    if [[ "$wahl" =~ ^[0-9]+$ ]] && [ "$wahl" -ge 1 ] && [ "$wahl" -le "$ANZAHL" ]; then break; fi
    echo "Bitte eine Zahl von 1 bis $ANZAHL eingeben."
  done
  GERAET_ZEILE="$(printf '%s\n' "$LISTE" | sed -n "${wahl}p")"
fi
GERAET="$(printf '%s' "$GERAET_ZEILE" | cut -f1)"
GERAET_NAME="$(printf '%s' "$GERAET_ZEILE" | cut -f2)"
echo "Gewählt: $GERAET_NAME ($GERAET)"
echo

# ---------- 4. Bauen ----------
fett "4/5 Bauen ($KONFIG), beim ersten Mal dauert das einige Minuten"
if ! xcodebuild "${bauen_args[@]}" -destination "id=$GERAET" -allowProvisioningUpdates build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -10
  fehler "Bauen fehlgeschlagen. Vollständiges Protokoll: $LOG"
  if grep -qiE "No Account for Team|no accounts|provisioning profile|signing" "$LOG"; then
    echo "Signierung: In Xcode unter Einstellungen > Accounts die Apple-ID anmelden und in _Project/Signing.local.xcconfig DEVELOPMENT_TEAM (und eine eigene BROWSER_BUNDLE_ID) eintragen${TEAM_ID:+ (eingetragen: Team $TEAM_ID)}."
  fi
  if grep -qiE "locked|passcode|unavailable|not connected" "$LOG"; then
    echo "Gerät erreichbar? Apple TV aufwecken und die Fernbedienungs-Seite offen lassen."
  fi
  ende 1
fi
APP="$BUILD_DIR/Build/Products/$KONFIG-appletvos/Browser.app"
[ -d "$APP" ] || { fehler "Gebaute App nicht gefunden: $APP"; ende 1; }
echo "Gebaut: $APP"
echo

# Ablaufdatum des Profils
PROFIL="$APP/embedded.mobileprovision"
KOSTENLOS=0
ABLAUF=""
if [ -f "$PROFIL" ]; then
  INFO="$(security cms -D -i "$PROFIL" 2>/dev/null | python3 -c '
import plistlib, sys, datetime
p = plistlib.loads(sys.stdin.buffer.read())
e, c = p["ExpirationDate"], p.get("CreationDate")
gueltig = (e - c).days if c else -1
rest = (e - datetime.datetime.utcnow()).days
print(e.replace(tzinfo=datetime.timezone.utc).astimezone().strftime("%d.%m.%Y %H:%M"), gueltig, rest, sep="|")
' 2>/dev/null)"
  if [ -n "$INFO" ]; then
    ABLAUF="${INFO%%|*}"; rest="${INFO#*|}"; GUELTIG="${rest%%|*}"; TAGE="${rest#*|}"
    if [ "$GUELTIG" -ge 0 ] && [ "$GUELTIG" -le 8 ]; then KOSTENLOS=1; fi
    fett "Profil läuft ab am $ABLAUF (noch $TAGE Tage)"
    if [ "$KOSTENLOS" = 1 ]; then
      hinweis "Kostenloser Apple-Account erkannt (Profil gilt nur $GUELTIG Tage). Spätestens am $ABLAUF neu installieren,"
      hinweis "sonst startet die App nicht mehr. Dazu dieses Skript einfach erneut starten."
    fi
    echo
  else
    hinweis "Das Ablaufdatum des Profils ließ sich nicht lesen."
  fi
fi

# ---------- 5. Installieren ----------
fett "5/5 Auf $GERAET_NAME installieren"
if ! ausgabe=$(xcrun devicectl device install app --device "$GERAET" "$APP" 2>&1); then
  echo "$ausgabe" | tail -8
  fehler "Installieren fehlgeschlagen."
  echo "Apple TV aufwecken, im selben WLAN lassen und die Fernbedienungs-Seite offen halten, dann erneut versuchen."
  echo "Bei 'untrusted developer': am Apple TV Einstellungen > Allgemein > Geräteverwaltung."
  ende 1
fi
echo "$ausgabe" | tail -4
echo

if [ -z "$STARTEN" ]; then
  if [ -t 0 ]; then
    read -r -p "App jetzt starten? [J/n] " antw
    case "$antw" in n|N|nein|Nein) STARTEN=nein ;; *) STARTEN=ja ;; esac
  else
    STARTEN=nein
  fi
fi
if [ "$STARTEN" = ja ]; then
  if ! ausgabe=$(xcrun devicectl device process launch --device "$GERAET" --terminate-existing "$BUNDLE_ID" 2>&1); then
    echo "$ausgabe" | tail -3
    hinweis "Starten ging nicht; die App lässt sich am Apple TV selbst öffnen."
  fi
fi

echo
fett "Fertig."
if [ "$KOSTENLOS" = 1 ]; then hinweis "Erinnerung: spätestens am $ABLAUF neu installieren (alle 7 Tage)."; fi
ende 0
