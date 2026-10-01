#!/bin/bash
# The real app (no demo) in the simulator, pairing with an island over the internet from its pairing link, then each tab
# with what that PC really reports. The screenshots stay on the runner (they show that PC's readings); the app's log,
# which says only what worked and how many, is what's kept. Needs sim-app.zip (from the screens job) and PAIR_LINK.
set -u
BUNDLE=io.github.arnavdugad.arnavisland
OUT=live
mkdir -p "$OUT"
DEVICE=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
phones = [x for runtime, items in d.items() if "iOS" in runtime for x in items if x["name"].startswith("iPhone")]
liked = [x for x in phones if x["name"] in ("iPhone 16", "iPhone 17", "iPhone 15", "iPhone 16 Pro")]
print((liked or phones)[0]["udid"])')
echo "Simulator: $(xcrun simctl list devices available | grep "$DEVICE")"
rm -rf app && mkdir app && ditto -x -k sim-app.zip app
APP=$(ls -d app/*.app | head -1)
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl status_bar "$DEVICE" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 || true
xcrun simctl install "$DEVICE" "$APP"
for what in camera photos; do xcrun simctl privacy "$DEVICE" grant "$what" "$BUNDLE" 2>/dev/null || true; done
xcrun simctl ui "$DEVICE" appearance dark
# Pairs, and stays on the remote while the PC's status arrives.
xcrun simctl launch "$DEVICE" "$BUNDLE" -quiet -pairlink "$PAIR_LINK" -tab 0 >/dev/null
sleep 45
xcrun simctl io "$DEVICE" screenshot "$OUT/remote.png" >/dev/null 2>&1 && echo "shot remote"
shot() { # name, tab
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch "$DEVICE" "$BUNDLE" -quiet -tab "$2" >/dev/null
  sleep 25
  xcrun simctl io "$DEVICE" screenshot "$OUT/$1.png" >/dev/null 2>&1 && echo "shot $1"
}
shot island 1
shot shelf 3
shot devices 4
shot remote-again 0
xcrun simctl spawn "$DEVICE" log show --last 10m --info --predicate 'subsystem == "io.github.arnavdugad.arnavisland"' --style compact > "$OUT/app.log" 2>/dev/null || true
xcrun simctl spawn "$DEVICE" log show --last 10m --predicate 'process == "ArnavIsland" AND (messageType == error OR messageType == fault)' --style compact > "$OUT/errors.log" 2>/dev/null || true
xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
ls -la "$OUT"
