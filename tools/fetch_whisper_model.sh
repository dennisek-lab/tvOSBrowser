#!/bin/bash
# Lädt ein whisper.cpp-Modell (ggml) nach _Project/Browser/WhisperModels/ (Ordnerreferenz im
# App-Paket, Inhalt nicht im Git).
#
# Aufruf:
#   tools/fetch_whisper_model.sh                 # Standard: base-q5_1 (mehrsprachig, erkennt die Sprache, ~57 MB)
#   tools/fetch_whisper_model.sh base.en-q5_1    # nur Englisch (~57 MB), für Englisch etwas genauer
#   tools/fetch_whisper_model.sh tiny-q5_1       # mehrsprachig, kleiner/schneller (~31 MB), ungenauer
#   tools/fetch_whisper_model.sh small-q5_1      # mehrsprachig, deutlich genauer (~181 MB), ~3x langsamer
#
# Die App nimmt das erste vorhandene Modell in dieser Reihenfolge: bei „Automatisch“ und festen
# Sprachen außer Englisch ein mehrsprachiges (base-q5_1, base-q8_0, base, small-q5_1, tiny-q5_1, tiny),
# bei „Englisch“ zuerst base.en-q5_1, tiny.en-q5_1 (siehe BrowserSubtitleEngine.m, +modelCandidates).
# Ohne mehrsprachiges Modell gibt es nur englische Untertitel. Mehrere Modelle gleichzeitig sind
# möglich, machen die App aber größer.
set -euo pipefail

NAME="${1:-base-q5_1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="$ROOT/_Project/Browser/WhisperModels"
FILE="ggml-$NAME.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$FILE"

mkdir -p "$DEST_DIR"
if [[ -s "$DEST_DIR/$FILE" ]]; then
    echo "vorhanden: $DEST_DIR/$FILE ($(du -h "$DEST_DIR/$FILE" | cut -f1))"
    exit 0
fi
echo "lade $URL"
curl -L --fail --progress-bar -o "$DEST_DIR/$FILE.part" "$URL"
mv "$DEST_DIR/$FILE.part" "$DEST_DIR/$FILE"
echo "fertig: $DEST_DIR/$FILE ($(du -h "$DEST_DIR/$FILE" | cut -f1))"
