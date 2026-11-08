#!/bin/bash
# Lädt ein whisper.cpp-Modell (ggml) nach _Project/Browser/WhisperModels/ (Ordnerreferenz im
# App-Paket, Inhalt nicht im Git).
#
# Aufruf:
#   tools/fetch_whisper_model.sh                 # Standard: base.en-q5_1 (Englisch, ~57 MB)
#   tools/fetch_whisper_model.sh tiny.en-q5_1    # kleiner/schneller (~31 MB), bei Leistungsproblemen
#   tools/fetch_whisper_model.sh base-q5_1       # mehrsprachig (Deutsch usw., ~57 MB)
#
# Die App nimmt das erste vorhandene Modell in dieser Reihenfolge: bei „Sprache automatisch“
# ein mehrsprachiges (base-q5_1, tiny-q5_1), sonst base.en-q5_1, tiny.en-q5_1 (siehe
# BrowserSubtitleEngine.m, +modelCandidates). Mehrere Modelle gleichzeitig sind möglich,
# machen die App aber größer.
set -euo pipefail

NAME="${1:-base.en-q5_1}"
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
