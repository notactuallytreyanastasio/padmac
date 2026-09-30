# Remote Mac

Control a Mac from an iPad over the local network. Two apps:

- **Remote Mac Host** (macOS menu-bar app) captures a display with
  ScreenCaptureKit and hardware-encodes it to HEVC at native resolution. It
  falls back to H.264, capped at 4096 px wide. It injects the iPad's input
  with CGEvent and syncs clipboard text.
- **Remote Mac** (iPad app) finds hosts over Bonjour, decodes the stream with
  `AVSampleBufferDisplayLayer`, and sends touch, trackpad and keyboard input.
  It reconnects on its own after being backgrounded or losing Wi-Fi.

The link is TLS 1.2 with a pre-shared key derived from an 8-character pairing
code that the host shows. There are no certificates and no accounts. A client
without the code fails the handshake (`-9820: bad MAC`).

## Install

```sh
brew install xcodegen          # if needed
./scripts/install-host.sh      # builds, copies to /Applications, launches
```

Click the display icon in the menu bar. Grant **Screen Recording** and
**Accessibility**, then quit and reopen the host once (macOS only applies Screen
Recording on relaunch). The pairing code is shown there too.

On the iPad, pick one:

- **Directly from this Mac (recommended, no 7-day expiry with a paid team).**
  Plug the iPad in, trust the Mac, enable Developer Mode, then run
  `./scripts/install-ipad.sh`.
- **Sideloadly / AltStore.** `./scripts/build-ipa.sh` writes an unsigned
  `RemoteMac.ipa`; the tool re-signs it with your Apple ID.

Open Remote Mac, tap your Mac, and enter the code. It's stored in the iPad keychain.
If Bonjour can't see the Mac (e.g. over Tailscale), connect by address. The port is 47428.

## Controls

| Input | Trackpad mode (default) | Direct mode |
|---|---|---|
| 1-finger drag | move cursor (relative, accelerated) | drag with button held |
| tap | click (double-tap = double-click) | click there |
| 2-finger tap | right-click | right-click there |
| 2-finger drag | scroll | scroll |
| touch, hold, drag | drag | — |
| pinch | zoom (1–8×) | zoom (1–8×) |
| 3-finger drag | pan the zoomed view | pan the zoomed view |

While zoomed, the view follows the Mac cursor. The toolbar's magnifier toggles
between the whole display and filling the iPad's short side, which is the
useful zoom for an ultrawide. A display button appears when the Mac has more
than one active display.

Clipboard text copied on the Mac shows up on the iPad right away. Anything
a password manager marks as concealed stays on the Mac. Going the other way,
the toolbar's paste button puts the iPad clipboard on the Mac and presses ⌘V.
It's a system paste control, so iPadOS doesn't ask permission each time.

An iPad trackpad or mouse maps absolutely: hover puts the Mac cursor under it,
click and right-click work, and two-finger scrolling scrolls. The iPad's own
pointer is hidden because the Mac's cursor is in the video.

A hardware keyboard sends real key codes, including modifiers and arrow and
function keys, with key repeat. The on-screen keyboard (toolbar ⌨) types
literal text and has an accessory row: esc, tab, sticky ⌃⌥⌘⇧ and arrows.
Sticky modifiers apply to the next key, so ⌘ then `c` copies.

## Verifying a host without an iPad

```sh
xcodebuild -scheme probe -derivedDataPath build build
build/Build/Products/Debug/probe 127.0.0.1 <CODE> frame.png --move --displays --clipboard
```

The probe connects like the iPad does, decodes every frame with VideoToolbox,
writes one to `frame.png`, and checks that absolute and relative cursor moves
land where expected. `--displays` switches display (or restarts the stream
if there's only one). `--clipboard` round-trips the pasteboard and restores
it afterwards. Each check prints PASS/FAIL, and `--h264` forces the
fallback codec. Don't touch the mouse while it runs.

To run a second host next to an installed one, launch the binary with
`-port 47429 -pairingCode TESTCODE` and point the probe at `127.0.0.1:47429`.

## What does not work / not done

- **Switching to a second display is untested.** The dev Mac had its lid
  closed, so only one display was active. Re-selecting the same display (the
  path a resolution change also takes) is tested.
- **Older iPads and 5120-wide HEVC.** The client asks for up to twice its own
  resolution, so an ultrawide streams at 5120×1440. M-series iPads decode that
  easily. An A12-era iPad may not. If the picture stays black, that's the
  first suspect.
- **No audio.**
- **iPadOS keeps some shortcuts.** ⌘-Tab, ⌘-Space and Globe shortcuts go to the iPad, not the Mac.
- **Clipboard is text only.** No images or files.
- **Local network only by design.** The 40-bit code resists online guessing,
  but a captured handshake could be brute-forced offline. Don't port-forward
  47428 to the internet. Use Tailscale or another VPN.
- **Tested in the iOS Simulator and with the probe, not yet on a physical iPad.**
  Trackpad/mouse and hardware-keyboard paths especially need a real device.
