#!/bin/bash
# Baut whisper.cpp (mit Metal) als statisches xcframework für tvOS (Gerät arm64 + Simulator arm64).
#
# Aufruf (aus dem Repo-Wurzelordner oder von überall):
#   tools/build_whisper.sh            # holt die Quelle, falls nötig, und baut
#   tools/build_whisper.sh --clean    # Build-Ordner vorher löschen
#
# Ergebnis: vendor/whisper.xcframework (statisch, ≈17 MB, wird committet).
# Metal-Kernel (Gerät): Ist die Metal-Toolchain installiert (xcodebuild -downloadComponent MetalToolchain),
# werden sie für tvOS (-mtargetos=tvos…) vorkompiliert nach vendor/whisper-metal/appletvos/default.metallib
# (≈15 MB, wird committet; das Framework enthält dann keinen Kernel-Quelltext mehr). Die Build-Phase
# „Whisper-Metal-Kernel kopieren“ legt sie ins App-Paket, dort sucht ggml sie. Ohne Toolchain (oder mit
# WHISPER_METAL_EMBED=ON) wird der Kernel-Quelltext eingebettet und beim ersten Laden des Modells zur
# Laufzeit übersetzt (Simulator ≈16 s). ggml-tensor.metallib (Tensor-API) wird nicht übernommen: ggml nutzt
# sie erst ab A19/M5, kein Apple TV hat das.
# Simulator: immer eingebettet (WHISPER_METAL_SIM_EMBED=ON), weil whisper dort ohnehin auf der CPU rechnet
# (Simulator-GPU kann die Kernel nicht); spart 15 MB vorkompilierte Kernel im Repo.
# Das Xcode-Projekt sucht das Framework über FRAMEWORK_SEARCH_PATHS in
# $(SRCROOT)/../vendor/whisper.xcframework/tvos-arm64[-simulator] und bindet es per
# Modul-Autolink ein (#import <whisper/whisper.h>). Fehlt es, baut die App trotzdem,
# die automatischen Untertitel melden dann „nicht verfügbar“.
#
# Voraussetzungen: Xcode (xcodebuild, libtool), git, python3. CMake wird, falls nicht
# installiert, in vendor/tools-venv per pip nachgeladen.
set -euo pipefail

WHISPER_TAG="${WHISPER_TAG:-v1.9.5}"
TVOS_MIN="${TVOS_MIN:-17.0}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
SRC="$VENDOR/whisper.cpp"
OUT="$VENDOR/whisper.xcframework"
WORK="$VENDOR/whisper-build"

mkdir -p "$VENDOR"

if [[ "${1:-}" == "--clean" ]]; then
    rm -rf "$WORK" "$OUT"
fi

# 1. Quelle
if [[ ! -d "$SRC/.git" ]]; then
    echo "== whisper.cpp $WHISPER_TAG holen"
    git clone --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp "$SRC"
else
    echo "== whisper.cpp vorhanden: $(git -C "$SRC" describe --tags 2>/dev/null || git -C "$SRC" rev-parse --short HEAD)"
fi

# 2. CMake
CMAKE="$(command -v cmake || true)"
if [[ -z "$CMAKE" ]]; then
    if [[ ! -x "$VENDOR/tools-venv/bin/cmake" ]]; then
        echo "== CMake fehlt, lade es per pip nach vendor/tools-venv"
        python3 -m venv "$VENDOR/tools-venv"
        "$VENDOR/tools-venv/bin/pip" install -q --upgrade pip cmake
    fi
    CMAKE="$VENDOR/tools-venv/bin/cmake"
fi
echo "== $("$CMAKE" --version | head -1)"

# 3. Metal-Kernel vorkompilieren, wenn die Metal-Toolchain da ist
if [[ -z "${WHISPER_METAL_EMBED:-}" ]]; then
    if xcrun -sdk appletvos metal --version >/dev/null 2>&1; then
        WHISPER_METAL_EMBED=OFF
    else
        WHISPER_METAL_EMBED=ON
        echo "== Metal-Toolchain fehlt: Kernel werden eingebettet und zur Laufzeit übersetzt"
        echo "   (vorkompilieren: xcodebuild -downloadComponent MetalToolchain, dann erneut bauen)"
    fi
fi
WHISPER_METAL_SIM_EMBED="${WHISPER_METAL_SIM_EMBED:-ON}"
echo "== GGML_METAL_EMBED_LIBRARY Gerät=$WHISPER_METAL_EMBED Simulator=$WHISPER_METAL_SIM_EMBED"

COMMON=(
    -G Xcode
    -DCMAKE_SYSTEM_NAME=tvOS
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$TVOS_MIN"
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
    -DBUILD_SHARED_LIBS=OFF
    -DWHISPER_BUILD_EXAMPLES=OFF
    -DWHISPER_BUILD_TESTS=OFF
    -DWHISPER_BUILD_SERVER=OFF
    -DGGML_METAL=ON
    -DGGML_METAL_TARGET_OS=tvos
    -DGGML_METAL_USE_BF16=ON
    -DGGML_BLAS_DEFAULT=ON
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=OFF
    -DCMAKE_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument"
    -DCMAKE_CXX_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument"
    -S "$SRC"
)

build_slice() {
    local sdk="$1"     # appletvos | appletvsimulator
    local embed="$2"   # ON: Kernel-Quelltext einbetten, OFF: default.metallib vorkompilieren
    local dir="$WORK/$sdk"
    echo "== Baue $sdk (Metal eingebettet: $embed)"
    "$CMAKE" -B "$dir" "${COMMON[@]}" \
        -DGGML_METAL_EMBED_LIBRARY="$embed" \
        -DCMAKE_OSX_SYSROOT="$sdk" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS="$sdk" >/dev/null
    "$CMAKE" --build "$dir" --config Release -- -quiet

    # Alle statischen Bibliotheken (whisper, ggml, ggml-base, ggml-cpu, ggml-metal, ggml-blas) zusammenfassen
    local libs
    libs=$(find "$dir" -path "*Release-$sdk*" -name "*.a" | sort)
    echo "$libs" | sed 's/^/   /'

    rm -rf "$VENDOR/whisper-metal/$sdk"
    if [[ "$embed" == "OFF" ]]; then
        # ggml legt die Bibliotheken in CMAKE_RUNTIME_OUTPUT_DIRECTORY ab (<build>/bin, ohne Konfigurationsordner)
        local metallib
        metallib=$(find "$dir" -name default.metallib -not -path "*/CMakeFiles/*" | head -1)
        if [[ -z "$metallib" ]]; then
            echo "default.metallib fehlt in $dir" >&2
            exit 1
        fi
        mkdir -p "$VENDOR/whisper-metal/$sdk"
        cp "$metallib" "$VENDOR/whisper-metal/$sdk/default.metallib"
        echo "   Metal: $(du -h "$VENDOR/whisper-metal/$sdk/default.metallib" | cut -f1) $metallib"
    fi

    local fw="$dir/framework/whisper.framework"
    rm -rf "$fw"
    mkdir -p "$fw/Headers" "$fw/Modules"
    # shellcheck disable=SC2086
    xcrun libtool -static -no_warning_for_no_symbols -o "$fw/whisper" $libs
    cp "$SRC/include/whisper.h" "$SRC/ggml/include/ggml.h" "$SRC/ggml/include/ggml-alloc.h" \
       "$SRC/ggml/include/ggml-backend.h" "$SRC/ggml/include/ggml-metal.h" "$SRC/ggml/include/ggml-cpu.h" \
       "$SRC/ggml/include/ggml-blas.h" "$SRC/ggml/include/gguf.h" "$fw/Headers/"
    cat > "$fw/Modules/module.modulemap" <<'EOF'
framework module whisper {
    header "whisper.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"

    link framework "whisper"
    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "MetalKit"
    link framework "Foundation"

    export *
}
EOF
    cat > "$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>whisper</string>
    <key>CFBundleIdentifier</key><string>org.ggml.whisper</string>
    <key>CFBundleName</key><string>whisper</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>${WHISPER_TAG#v}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>${TVOS_MIN}</string>
</dict>
</plist>
EOF
}

build_slice appletvos "$WHISPER_METAL_EMBED"
build_slice appletvsimulator "$WHISPER_METAL_SIM_EMBED"

echo "== xcframework"
rm -rf "$OUT"
xcodebuild -create-xcframework \
    -framework "$WORK/appletvos/framework/whisper.framework" \
    -framework "$WORK/appletvsimulator/framework/whisper.framework" \
    -output "$OUT" >/dev/null
ls "$OUT"
du -sh "$OUT"/*/whisper.framework/whisper
echo "== fertig: $OUT"
