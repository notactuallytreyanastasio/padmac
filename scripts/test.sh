#!/bin/zsh
# Runs every automated test.
#
#   scripts/test.sh          everything that leaves this Mac's cursor and clipboard alone
#   scripts/test.sh --live   also the probe checks that really move the cursor,
#                            round-trip the clipboard, swipe to the next desktop
#                            and back, play a ping to check audio arrives, and
#                            use ⌥Tab / ⌥Space to switch apps and open Spotlight
#                            (don't touch the mouse meanwhile)
#
# Needs Screen Recording permission for your terminal (the host it starts
# captures the screen). The iPad tests use REMOTEMAC_SIM, default "iPad Pro 13-inch (M5)".
set -uo pipefail
cd "${0:A:h}/.."

DD=build-test
PORT=47439
CODE=TESTCODE
SIM=${REMOTEMAC_SIM:-"iPad Pro 13-inch (M5)"}
LOG=$PWD/$DD/input.jsonl
LIVE=${1:-}
mkdir -p $DD
failed=()

step() { print -P "\n%B== $1%b" }

# Run xcodebuild, keep the full log, show only results.
xcb() {
  local name=$1; shift
  xcodebuild -project RemoteMac.xcodeproj -derivedDataPath $DD "$@" > $DD/$name.log 2>&1
  local rc=$?
  grep -E "error:|Test Case .* failed|XCTAssert|Executed [0-9]+ tests|\*\* (BUILD|TEST) (SUCCEEDED|FAILED)" $DD/$name.log \
    | grep -v "^\s*$" | sed -E 's/^.*(Test Case|Executed)/  \1/' | sort -u
  if (( rc != 0 )); then failed+=$name; print "  (full log: $DD/$name.log)"; fi
  return $rc
}

host_pid=
start_host() {
  [[ -n $host_pid ]] && kill $host_pid 2>/dev/null && wait $host_pid 2>/dev/null
  : > $LOG
  $DD/Build/Products/Debug/RemoteMacHost.app/Contents/MacOS/RemoteMacHost \
    -port $PORT -pairingCode $CODE -noBonjour YES -inputLog $LOG "$@" > $DD/host.log 2>&1 &
  host_pid=$!
  for i in {1..50}; do lsof -iTCP:$PORT -sTCP:LISTEN -n >/dev/null 2>&1 && return 0; sleep 0.1; done
  print "host did not start listening on $PORT"; cat $DD/host.log; return 1
}
trap '[[ -n $host_pid ]] && kill $host_pid 2>/dev/null' EXIT

xcodegen generate -q

step "Mac unit tests"
xcb mac-tests test -scheme RemoteMacHost -destination platform=macOS -allowProvisioningUpdates

step "Build host and probe"
xcb host-build build -scheme RemoteMacHost -destination platform=macOS -allowProvisioningUpdates &&
xcb probe-build build -scheme probe -destination platform=macOS

step "Start dry-run host on :$PORT (input is logged, not posted)"
start_host -dryRunInput YES && print "  pid $host_pid"

step "Probe: real capture -> HEVC -> TLS -> decode, and a stream restart"
latency_flag=()
if netstat -an -p tcp 2>/dev/null | grep -q '\.47428 .*ESTABLISHED'; then
  # Two capture+encode pipelines on one Mac: the second measures ~125ms instead of ~15ms.
  print "  note: a device is connected to the installed host, so the latency check is skipped (it would read ~125ms)"
  latency_flag=(--no-latency-check)
fi
if $DD/Build/Products/Debug/probe 127.0.0.1:$PORT $CODE $DD/probe.png --displays $latency_flag | sed 's/^/  /'; then :; else failed+=probe; fi

step "iPad unit and UI tests on $SIM"
TEST_RUNNER_REMOTEMAC_HOST=127.0.0.1:$PORT TEST_RUNNER_REMOTEMAC_INPUT_LOG=$LOG TEST_RUNNER_REMOTEMAC_CODE=$CODE \
  xcb ipad-tests test -scheme RemoteMac -destination "platform=iOS Simulator,name=$SIM" -parallel-testing-enabled NO

if [[ $LIVE == --live ]]; then
  step "Live probe: real cursor and clipboard"
  start_host
  if $DD/Build/Products/Debug/probe 127.0.0.1:$PORT $CODE $DD/probe-live.png --move --clipboard --swipe --audio --keys | sed 's/^/  /'; then :; else failed+=probe-live; fi
fi

print
if (( ${#failed} )); then print -P "%F{red}%BFAILED:%b ${failed[*]}%f"; exit 1; fi
print -P "%F{green}%BAll tests passed.%b%f"
