#!/bin/bash
# The app in the simulator with a made-up PC (-demo): a screenshot of every tab and the main sheets, dark and light.
# Picks an iPhone like an iPhone 15 (a 6.1-inch screen with a Dynamic Island). Writes shots/ and sim-build.log.
set -u
BUNDLE=io.github.arnavdugad.arnavisland
OUT=shots
mkdir -p "$OUT"
xcodegen generate
DEVICE=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
phones = [x for runtime, items in d.items() if "iOS" in runtime for x in items if x["name"].startswith("iPhone")]
liked = [x for x in phones if x["name"] in ("iPhone 16", "iPhone 17", "iPhone 15", "iPhone 16 Pro")]
print((liked or phones)[0]["udid"])')
echo "Simulator: $(xcrun simctl list devices available | grep "$DEVICE")"
set -o pipefail
# Signed "to run locally" (ad hoc): the simulator's keychain wants a signed app, which the live test needs.
xcodebuild -project ArnavIsland.xcodeproj -scheme ArnavIsland -configuration Debug -sdk iphonesimulator -destination "id=$DEVICE" -derivedDataPath build \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- build 2>&1 | tee sim-build.log | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP=build/Build/Products/Debug-iphonesimulator/ArnavIsland.app
test -d "$APP" || exit 1
set +o pipefail
# Kept for the live test (scripts/live.sh), which installs it in a fresh simulator.
ditto -c -k --keepParent "$APP" sim-app.zip
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl status_bar "$DEVICE" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 || true
xcrun simctl install "$DEVICE" "$APP"
# The simulator's permissions, given up front (no camera prompt over the pairing sheet).
for what in camera photos notifications; do xcrun simctl privacy "$DEVICE" grant "$what" "$BUNDLE" 2>/dev/null || true; done
shot() { # name, appearance, then launch arguments
  local name="$1" look="$2"; shift 2
  xcrun simctl ui "$DEVICE" appearance "$look" || true
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch "$DEVICE" "$BUNDLE" -demo "$@" >/dev/null
  sleep 9
  xcrun simctl io "$DEVICE" screenshot "$OUT/$name.png" >/dev/null 2>&1 && echo "shot $name"
}
# A first launch to warm up (the very first one is slow: its frames would show the launch screen).
xcrun simctl launch "$DEVICE" "$BUNDLE" -demo >/dev/null; sleep 12
shot remote-dark dark -tab 0
shot island-dark dark -tab 1
shot send-dark dark -tab 2 -transfer 1
shot shelf-dark dark -tab 3
shot devices-dark dark -tab 4
shot remote-light light -tab 0
shot island-light light -tab 1
shot banner-dark dark -tab 0 -banner "Received Moodboard.png"
shot pair-dark dark -tab 0 -open pair
shot trackpad-dark dark -tab 0 -open trackpad
shot player-dark dark -tab 0 -open player
shot music-dark dark -tab 0 -open music
shot offer-dark dark -tab 2 -open offer
shot ring-dark dark -tab 0 -open ring
shot send-light light -tab 2 -transfer 1
shot devices-light light -tab 4
xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
ls -la "$OUT"
