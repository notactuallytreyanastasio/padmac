# Remote Mac

Control a Mac from an iPad over the local network. Two apps:

- **Remote Mac Host** (macOS menu-bar app) captures the main display with
  ScreenCaptureKit, hardware-encodes it to H.264, and injects the iPad's
  input with CGEvent.
- **Remote Mac** (iPad app) finds hosts over Bonjour, decodes the stream with
  `AVSampleBufferDisplayLayer`, and sends touch, trackpad and keyboard input.

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
build/Build/Products/Debug/probe 127.0.0.1 <CODE> frame.png --move
```

The probe connects like the iPad does, decodes every frame with VideoToolbox,
writes one to `frame.png`, and checks that absolute and relative cursor moves
land where expected. It also prints PASS/FAIL. Don't touch the mouse while it runs.

## What does not work / not done

- **Main display only.** Other displays aren't selectable, and a resolution
  change mid-session isn't handled (reconnect).
- **No audio.**
- **iPadOS keeps some shortcuts.** ⌘-Tab, ⌘-Space and Globe shortcuts go to the iPad, not the Mac.
- **No pinch-to-zoom** on the remote screen.
- **No clipboard sync.**
- **Local network only by design.** The 40-bit code resists online guessing,
  but a captured handshake could be brute-forced offline. Don't port-forward
  47428 to the internet. Use Tailscale or another VPN.
- **Tested in the iOS Simulator and with the probe, not yet on a physical iPad.**
  Trackpad/mouse and hardware-keyboard paths especially need a real device.
