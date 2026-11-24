#!/usr/bin/env bash
# Install kvm-switch on KDE Plasma 6 (Wayland or X11):
#   Ctrl+Alt+Meta+K  hand keyboard/mouse (or, with PBP off, the screen) to the other computer
#   Ctrl+Alt+Meta+P  toggle PBP
# plus a system tray widget.
set -euo pipefail
cd "$(dirname "$0")"

BIN=$HOME/.local/bin/kvm-switch
APPS=$HOME/.local/share/applications
# Qt key codes: Meta(0x10000000) | Ctrl(0x04000000) | Alt(0x08000000) | letter
MODS=$(( 0x10000000 | 0x04000000 | 0x08000000 ))

command -v ddcutil >/dev/null || { echo "ddcutil is required" >&2; exit 1; }

install -Dm755 kvm-switch "$BIN"
echo "installed $BIN"

call() { gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
           --method "org.kde.KGlobalAccel.$1" "${@:2}" >/dev/null; }

# bind <desktop-id> <name> <exec args> <letter> <qt key code>
bind() {
  local id=$1 name=$2 args=$3 letter=$4 code=$5
  mkdir -p "$APPS"
  cat >"$APPS/$id.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Exec=$BIN $args
Icon=video-display
NoDisplay=true
X-KDE-GlobalAccel-CommandShortcut=true
EOF
  # Persist the binding (what System Settings → Shortcuts writes)...
  kwriteconfig6 --file kglobalshortcutsrc --group services --group "$id.desktop" \
    --key _launch "Ctrl+Alt+Meta+$letter"
  # ...and register it with the running kglobalaccel so it works without re-login.
  # flags 6 = SetPresent|NoAutoloading; without SetPresent the action stays inactive.
  local action="['$id.desktop', '_launch', '$name', '$name']"
  call doRegister "$action"
  call setShortcutKeys "$action" "[([$(( MODS | code )), 0, 0, 0],)]" 6
  echo "bound Ctrl+Alt+Meta+$letter → kvm-switch $args"
}

bind net.local.kvm-switch     "KVM Switch"     toggle K 0x4B
bind net.local.kvm-switch-pbp "KVM Toggle PBP" pbp    P 0x50

# System tray widget (shows who owns the keyboard; click for status and controls).
if kpackagetool6 -t Plasma/Applet -s io.github.potable-anarchy.kvmswitch >/dev/null 2>&1; then
  kpackagetool6 -t Plasma/Applet -u plasmoid
else
  kpackagetool6 -t Plasma/Applet -i plasmoid
fi
echo "installed tray widget (appears in the system tray; restart plasmashell if it doesn't)"
