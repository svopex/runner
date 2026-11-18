#!/usr/bin/env bash
# Sestaví Runner.app do složky build/, nainstaluje ji do /Applications a spustí.
# Použití:
#   ./run.sh              sestavení, instalace do /Applications a spuštění (Runner musí být ukončený)
#   ./run.sh --no-install jen sestavení do build/Runner.app
set -euo pipefail

# Pracujeme vždy v kořenu projektu, ať je skript spuštěný odkudkoli
cd "$(dirname "$0")"

APP_DIR="build/Runner.app"

# Zpracování parametrů – výchozí chování je sestavení i instalace
INSTALL=1
for arg in "$@"; do
    case "$arg" in
        --no-install) INSTALL=0 ;;
        *)
            echo "Neznámý parametr: $arg (povolený je jen --no-install)" >&2
            exit 1
            ;;
    esac
done

# Běžící Runner by držel starou binárku – kontrolujeme ještě před sestavením
if [ "$INSTALL" -eq 1 ] && pgrep -x Runner >/dev/null 2>&1; then
    echo "Runner právě běží – ukončete ho a spusťte skript znovu." >&2
    exit 1
fi

echo "Sestavuji (release)…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

# Složení balíčku .app: binárka, Info.plist a ikona
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/Runner" "$APP_DIR/Contents/MacOS/Runner"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

# Ad-hoc podpis – nutný pro spouštění po přihlášení (SMAppService)
codesign --force --sign - "$APP_DIR"
echo "Sestaveno: $APP_DIR"

# Instalace do /Applications a spuštění nainstalované aplikace (vynechá se s --no-install)
if [ "$INSTALL" -eq 1 ]; then
    rm -rf /Applications/Runner.app
    ditto "$APP_DIR" /Applications/Runner.app
    echo "Nainstalováno do /Applications/Runner.app"
    open /Applications/Runner.app
    echo "Runner spuštěn."
fi
