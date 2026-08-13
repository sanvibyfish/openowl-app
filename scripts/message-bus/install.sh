#!/usr/bin/env bash
# Install message-bus CLI into ~/.openowl/bin and wire the openOwl project.
#   scripts/message-bus/install.sh
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.openowl/bin"
mkdir -p "$BIN"

for tool in openowl bus-send bus-ack bus-list; do
  cp "$SRC/$tool" "$BIN/$tool"
  chmod +x "$BIN/$tool"
done
# Shared lib must live next to the CLIs.
cp "$SRC/buslib.py" "$BIN/buslib.py"

echo "installed to $BIN:"
ls -l "$BIN" | grep -E "openowl|bus"
echo
echo "PATH (zsh): add once to ~/.zshrc:"
echo '  export PATH="$HOME/.openowl/bin:$PATH"'
echo
echo "Try: openowl bus-list"
