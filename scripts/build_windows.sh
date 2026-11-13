#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
TARGET="x86_64-pc-windows-gnu"
OUTPUT="${TVREMOTE_BUILD_DIR:-$ROOT_DIR/build/TVRemoteMouse-Windows}"
DOTNET_BIN="${TVREMOTE_DOTNET:-dotnet}"
mkdir -p "$OUTPUT"
cargo build --release -p atv-cli --target "$TARGET"
"$DOTNET_BIN" publish windows-app/TVRemoteMouse.csproj -c Release -r win-x64 --self-contained true -o "$OUTPUT"
cp "target/$TARGET/release/atv-cli.exe" "$OUTPUT/TVRemoteMouse.Core.exe"
cp windows-app/README.md "$OUTPUT/README.md"
(cd "$(dirname "$OUTPUT")" && zip -q -r -FS "$ROOT_DIR/build/TVRemoteMouse-windows-x64.zip" "$(basename "$OUTPUT")")
echo "Package: $ROOT_DIR/build/TVRemoteMouse-windows-x64.zip"
