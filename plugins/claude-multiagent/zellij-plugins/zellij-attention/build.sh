#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Ensure the WASM target is installed
rustup target add wasm32-wasip1 2>/dev/null || true

# Build in release mode
cargo build --release

# Copy the built WASM to the standard location
WASM_FILE="target/wasm32-wasip1/release/zellij-attention.wasm"
if [ -f "$WASM_FILE" ]; then
    DEST="${HOME}/.config/zellij/plugins/zellij-attention.wasm"
    mkdir -p "$(dirname "$DEST")"
    cp "$WASM_FILE" "$DEST"
    echo "Installed: $DEST"
else
    echo "ERROR: Build succeeded but WASM file not found at $WASM_FILE" >&2
    exit 1
fi
