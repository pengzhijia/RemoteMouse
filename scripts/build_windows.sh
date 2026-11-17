#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v cargo >/dev/null && command -v rustup >/dev/null; then
  RUST_TOOLCHAIN="$(rustup toolchain list | sed -n '1s/ .*//p')"
  export PATH="$HOME/.rustup/toolchains/$RUST_TOOLCHAIN/bin:$PATH"
fi
cd "$ROOT_DIR"
TARGET="x86_64-pc-windows-gnu"
OUTPUT="${TVREMOTE_BUILD_DIR:-$ROOT_DIR/build/RemoteMouse-Windows}"
DOTNET_BIN="${TVREMOTE_DOTNET:-dotnet}"
if [ "$DOTNET_BIN" = dotnet ] && [ -x "$ROOT_DIR/build/tools/dotnet/dotnet" ]; then
  DOTNET_BIN="$ROOT_DIR/build/tools/dotnet/dotnet"
fi
mkdir -p "$OUTPUT"
swift scripts/generate_windows_icon.swift
cargo build --release -p atv-cli --target "$TARGET"
cargo build --release --manifest-path integrations/web-remote/windows/Cargo.toml --target "$TARGET"
"$DOTNET_BIN" publish windows-app/RemoteMouse.csproj -c Release -r win-x64 --self-contained true -o "$OUTPUT"
cp "target/$TARGET/release/atv-cli.exe" "$OUTPUT/RemoteMouse.Core.exe"
cp "integrations/web-remote/windows/target/$TARGET/release/PCRemote.exe" "$OUTPUT/RemoteMouse.WebRemote.exe"
cp windows-app/README.md "$OUTPUT/README.md"
(cd "$(dirname "$OUTPUT")" && zip -q -r -FS "$ROOT_DIR/build/RemoteMouse-windows-x64.zip" "$(basename "$OUTPUT")")
echo "Package: $ROOT_DIR/build/RemoteMouse-windows-x64.zip"
