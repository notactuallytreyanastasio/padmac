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
Recording on relaunch). The pairing code is shown there too, along with who's
connected, a Disconnect button, and "Open at login". While an iPad is
connected, the Mac's display is woken and kept from sleeping.

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
| pinch | zoom (1–8×); move the pinch to pan | same |
| 3-finger swipe left/right | next/previous desktop, following your fingers like a Mac trackpad | same |
| 3-finger swipe up/down | Mission Control / App Exposé | same |

While zoomed, the view follows the Mac cursor. The toolbar's magnifier toggles
between the whole display and filling the iPad's short side, which is the
useful zoom for an ultrawide. A display button appears when the Mac has more
than one active display.

Sound: the Mac's audio plays on the iPad (16-bit 48 kHz stereo, about 1.5
Mbit/s, ~60 ms behind). The speaker button turns it off, and the choice is
remembered. The Mac keeps playing through its own speakers too.

Clipboard: text and images copied on the Mac show up on the iPad right away.
If both are there, the image wins. Images over 16 MB are skipped. Anything
a password manager marks as concealed stays on the Mac. Going the other way,
the toolbar's paste button puts the iPad clipboard (text or image) on the Mac
and presses ⌘V. It's a system paste control, so iPadOS doesn't ask
permission each time.

Away from home: there's nothing to set up beyond Tailscale on both devices.
Bonjour doesn't cross Tailscale, so connect **by address** using the Mac's
Tailscale name or 100.x address. Only a device with the pairing code can
take over the session. Others are refused before they can disturb it.

An iPad trackpad or mouse maps absolutely: hover puts the Mac cursor under it,
click and right-click work, and two-finger scrolling scrolls. The iPad's own
pointer is hidden because the Mac's cursor is in the video.

A hardware keyboard sends real key codes, including modifiers and arrow and
function keys, with key repeat. The on-screen keyboard (toolbar ⌨) types
literal text and has an accessory row: esc, tab, sticky ⌃⌥⌘⇧ and arrows.
Sticky modifiers apply to the next key, so ⌘ then `c` copies.

## Tests

```sh
./scripts/test.sh          # everything; leaves your cursor and clipboard alone
./scripts/test.sh --live   # also moves the real cursor and round-trips the clipboard
```

What runs:

| Layer | Where | What it proves |
|---|---|---|
| `RemoteMacTests` (52) | macOS | Wire format round-trips and rejects malformed input. Framing over a real TLS-PSK socket: 5 MB messages, wrong code rejected, unknown or oversized messages hang up, video backpressure. HEVC at 5120×1440 and H.264 encoded and decoded through the real pipeline. Input logic: double-click counting, ⌘ flags on ⌘C, key repeat, text chunking, the lost-delta bug. The iPad key map checked against macOS's real US layout. The host server in dry-run mode. The display staying awake only while an iPad is connected. |
| `RemoteMacClientTests` (14) | iPad simulator | Zoom/pan geometry (no gaps, the pinch anchor stays put, follow-the-cursor) and three-finger swipe axis locking. |
| `RemoteMacUITests` (10) | iPad simulator | The real app, with real taps, drags, pinches and keyboard keys, against a real host in `-dryRunInput` mode. Assertions are on the input the host received. |
| `probe` | macOS | Real screen capture → HEVC → TLS → decode, a stream restart, and median capture-to-decode latency under 50 ms (this Mac: ~18 ms idle, ~40 ms under heavy load). |

The UI tests need the simulator's on-screen keyboard (I/O › Keyboard ›
Connect Hardware Keyboard off). The host needs Screen Recording permission
for your terminal.

The probe also works on its own, against any host:

```sh
probe <host[:port]> <code> frame.png [--move] [--displays] [--clipboard] [--swipe] [--h264] [--latency]
```

To run a second host next to an installed one, launch its binary with
`-port 47429 -pairingCode TESTCODE`. Add `-dryRunInput YES -inputLog <path>`
and it logs input instead of posting it. `-traceLatency YES` logs where the
time goes between capture and the wire.

## What does not work / not done

- **Switching to a second display is untested.** The dev Mac had its lid
  closed, so only one display was active. Re-selecting the same display (the
  path a resolution change also takes) is tested.
- **Older iPads and 5120-wide HEVC.** The client asks for up to twice its own
  resolution, so an ultrawide streams at 5120×1440. M-series iPads decode that
  easily. An A12-era iPad may not. If the picture stays black, that's the
  first suspect.
- **Desktop swipes rely on undocumented Dock events.** The event layout is
  Mac Mouse Fix's, verified on macOS 26.2 (`probe --swipe` changes desktop and
  back and checks it through SkyLight). Mac Mouse Fix reports that macOS 27
  ignores these fields, so expect swipes to stop working there.
- **No audio.**
- **iPadOS keeps some shortcuts.** ⌘-Tab, ⌘-Space and Globe shortcuts go to the iPad, not the Mac.
- **Clipboard has no files**, only text and images.
- **The Mac still plays its own sound** while streaming it.
- **Two streams at once are slow.** While an iPad is connected, a second
  stream from the same Mac (the probe, in testing) measures ~125 ms
  capture-to-decode instead of 13–19 ms. One stream, the normal case, is
  unaffected. `test.sh` detects a live session and skips only the latency
  check, with a note. Why two real capture pipelines interfere is not known:
  two synthetic encoders side by side don't.
- **Locked-screen login is untested.** Typing your password at the lock
  screen from the iPad may be blocked by macOS secure input.
- **Local network only by design.** The 40-bit code resists online guessing,
  but a captured handshake could be brute-forced offline. Don't port-forward
  47428 to the internet. Use Tailscale or another VPN.
- **Tested in the iOS Simulator and with the probe, not yet on a physical iPad.**
  Trackpad/mouse and hardware-keyboard paths especially need a real device.
