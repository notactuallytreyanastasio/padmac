#!/bin/zsh
# Keeps Remote Mac Host running: starts it at login and restarts it within
# 10 seconds if it quits or crashes, so it's still there when you're away.
#
#   scripts/keepalive-host.sh           install and start
#   scripts/keepalive-host.sh --remove  stop keeping it alive (it also stops running)
#
# While this is on, "Quit" in the menu restarts the host. Use --remove to stop it.
set -euo pipefail
LABEL=com.bgrayson.remotemac.keepalive
PLIST=~/Library/LaunchAgents/$LABEL.plist
APP="/Applications/Remote Mac Host.app/Contents/MacOS/RemoteMacHost"
DOMAIN=gui/$(id -u)

launchctl bootout $DOMAIN/$LABEL 2>/dev/null || true
if [[ ${1:-} == --remove ]]; then
  rm -f $PLIST
  echo "Removed. Open /Applications/Remote Mac Host.app to run it by hand."
  exit 0
fi
[[ -x $APP ]] || { echo "Install the host first: scripts/install-host.sh" >&2; exit 1; }

mkdir -p ~/Library/LaunchAgents
cat > $PLIST <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <!-- The binary itself, not "open": launchd must own the process to restart it. -->
  <key>ProgramArguments</key><array><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST

# Hand over from a host started by hand, if any.
pkill -x RemoteMacHost || true
for i in {1..50}; do pgrep -x RemoteMacHost >/dev/null || break; sleep 0.1; done
launchctl bootstrap $DOMAIN $PLIST
for i in {1..50}; do pgrep -x RemoteMacHost >/dev/null && break; sleep 0.1; done
pgrep -x RemoteMacHost >/dev/null || { echo "launchd did not start the host" >&2; exit 1; }
echo "Remote Mac Host is now kept running by launchd ($LABEL)."
