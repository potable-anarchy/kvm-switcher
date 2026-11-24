# kvm-switch

One hotkey on both machines hands the Alienware AW3926QW's keyboard and mouse
to the other computer: **Ctrl+Alt+Super+K** on Linux, **Ctrl+Option+Cmd+K** on
the Mac (the same physical keys).

It checks whether the monitor is in PBP first:

| Monitor state | What the key does |
|---|---|
| PBP on | Toggles the USB/KVM only (VCP `0xE7 = 0xFF00`). Both pictures stay on screen. |
| PBP off | Switches the input to the other machine (VCP `0x60`), and the KVM follows. |

## Mac: KVM Switch.app

1. Download `KVM-Switch.zip` from [Releases](../../releases), unzip it, and drag **KVM Switch.app** into Applications.
2. Open it. The app is ad-hoc signed, not notarized, so macOS blocks the first launch. Go to System Settings → Privacy & Security, click **Open Anyway**, or run
   `xattr -dr com.apple.quarantine "/Applications/KVM Switch.app"`.
3. Optional: turn on **Launch at Login** from its menu-bar icon.

It's a menu-bar app with no Dock icon. The menu shows the PBP state and which machine has the keyboard.
The hotkey doesn't need Accessibility permission. It needs Apple Silicon and macOS 13 or later.

The Mac must be connected **directly to the monitor's USB-C port**. Through a dock, the dock
swallows DDC, and the monitor's USB has no path to the Mac.

To build it yourself on a Mac: `mac/build.sh`, which writes `build/KVM Switch.app`. It only needs the Xcode command line tools.

Command-line use: `"/Applications/KVM Switch.app/Contents/MacOS/KVMSwitch" --status | --toggle`

## Linux (KDE Plasma 6)

`./install-linux.sh` installs `kvm-switch` to `~/.local/bin` and binds the hotkey. It needs `ddcutil` and
read/write access to `/dev/i2c-*`. Run `kvm-switch status` to see the current state.

## Monitor registers (found by probing)

| VCP | Meaning |
|---|---|
| `0x60` | Input: `0x0f` DisplayPort-1 (Linux), `0x1b` USB-C (Mac), `0x11`/`0x12` HDMI. Read from the Mac in PBP, it returns `0x1B0F` (both inputs). |
| `0xE9` | PBP mode: `0x00` off, `0x24` on |
| `0xE7` | Write `0xFF00` to toggle the KVM (write-only; always reads `0x1500`) |

On the USB-C input, the monitor drops the first DDC message of each exchange. The Mac app
therefore sends every read request twice and every write twice, and the monitor acts on one of
the writes. Sending a single message fails silently. DisplayPort (Linux) doesn't need this.

Defaults can be overridden. On Linux: `KVM_LINUX_INPUT`, `KVM_MAC_INPUT`, `KVM_MODEL`, `KVM_BUS`.
On the Mac: `defaults write io.github.potable-anarchy.kvm-switch linuxInput -int 15`.
