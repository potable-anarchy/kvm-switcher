# kvm-switch

One hotkey on both machines hands the Alienware AW3926QW's keyboard and mouse
to the other computer: **Ctrl+Alt+Super+K** on Linux, **Ctrl+Option+Cmd+K** on
the Mac (the same physical keys).

It checks whether the monitor is in PBP first:

| Monitor state | What the key does |
|---|---|
| PBP on | Toggles the USB/KVM only (VCP `0xE7 = 0xFF00`). Both pictures stay on screen. |
| PBP off | Switches the input to the other machine (VCP `0x60`), and the KVM follows. |

`kvm-switch status` prints the PBP state, the active input, and which machine owns USB.

## Install

- **Linux (KDE Plasma 6):** `./install-linux.sh` (needs `ddcutil` and read/write access to `/dev/i2c-*`)
- **Mac (Apple Silicon):** `./install-mac.sh` (installs `m1ddc` and `skhd`; skhd needs Accessibility permission)

## Monitor registers (found by probing)

| VCP | Meaning |
|---|---|
| `0x60` | Input: `0x0f` DisplayPort-1 (Linux), `0x1b` USB-C (Mac), `0x11`/`0x12` HDMI |
| `0xE9` | PBP mode: `0x00` off, `0x24` on |
| `0xE7` | Write `0xFF00` to toggle the KVM (write-only; always reads `0x1500`) |

Defaults can be overridden with `KVM_LINUX_INPUT`, `KVM_MAC_INPUT`, `KVM_MODEL`,
`KVM_BUS` (Linux) and `KVM_M1DDC_DISPLAY` (Mac, e.g. `"display 2"`).
