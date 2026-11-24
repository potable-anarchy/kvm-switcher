#!/usr/bin/env bash
# Install kvm-switch on KDE Plasma 6 (Wayland or X11) and bind Ctrl+Alt+Meta+K.
set -euo pipefail
cd "$(dirname "$0")"

ID=net.local.kvm-switch
DESKTOP=$HOME/.local/share/applications/$ID.desktop
BIN=$HOME/.local/bin/kvm-switch
# Qt key code: Meta(0x10000000) | Ctrl(0x04000000) | Alt(0x08000000) | K(0x4B)
KEY=$(( 0x10000000 | 0x04000000 | 0x08000000 | 0x4B ))

command -v ddcutil >/dev/null || { echo "ddcutil is required" >&2; exit 1; }

install -Dm755 kvm-switch "$BIN"
echo "installed $BIN"

mkdir -p "$(dirname "$DESKTOP")"
cat >"$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=KVM Switch
Comment=Hand keyboard/mouse (or screen) to the other computer
Exec=$BIN
Icon=video-display
NoDisplay=true
X-KDE-GlobalAccel-CommandShortcut=true
EOF
echo "wrote $DESKTOP"

# Persist the binding (what System Settings → Shortcuts writes)...
kwriteconfig6 --file kglobalshortcutsrc --group services --group "$ID.desktop" \
  --key _launch "Ctrl+Alt+Meta+K"

# ...and register it with the running kglobalaccel so it works without re-login.
call() { gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
           --method "org.kde.KGlobalAccel.$1" "${@:2}" >/dev/null; }
ACTION="['$ID.desktop', '_launch', 'KVM Switch', 'KVM Switch']"
call doRegister "$ACTION"
# flags 6 = SetPresent|NoAutoloading; without SetPresent the action stays inactive.
call setShortcutKeys "$ACTION" "[([$KEY, 0, 0, 0],)]" 6
echo "bound Ctrl+Alt+Meta+K → $BIN"
