#!/usr/bin/env bash
# Install kvm-switch on an Apple Silicon Mac and bind Ctrl+Option+Cmd+K via skhd.
set -euo pipefail
cd "$(dirname "$0")"

[[ $(uname -m) == arm64 ]] || { echo "m1ddc needs Apple Silicon" >&2; exit 1; }
command -v brew >/dev/null || { echo "Homebrew is required" >&2; exit 1; }

brew list m1ddc >/dev/null 2>&1 || brew install m1ddc
brew list skhd  >/dev/null 2>&1 || brew install koekeishiya/formulae/skhd

BIN=$HOME/.local/bin/kvm-switch
install -d "$(dirname "$BIN")"
install -m755 kvm-switch "$BIN"
echo "installed $BIN"

RC=$HOME/.skhdrc
LINE="ctrl + alt + cmd - k : $BIN"
if ! grep -qF "$BIN" "$RC" 2>/dev/null; then
  printf '\n# kvm-switch: same physical keys as Ctrl+Alt+Super+K on Linux\n%s\n' "$LINE" >>"$RC"
  echo "added hotkey to $RC"
fi

skhd --start-service 2>/dev/null || skhd --restart-service
echo
echo "Done. If this is skhd's first run, allow it in"
echo "  System Settings → Privacy & Security → Accessibility"
echo "then test with:  $BIN status"
