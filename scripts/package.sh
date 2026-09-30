#!/bin/bash
# Packages the unsigned app into an IPA for sideloading. Each binary is fake-signed (ldid) with its entitlements, so AltStore
# or SideStore know which capabilities (the app group the widgets and the share sheet use) to set up when they sign it with
# your own Apple ID on your own iPhone.
set -euo pipefail
APP="$1"; OUT="$2"
ROOT="$(pwd)"
WORK="$(mktemp -d)"; mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
A="$WORK/Payload/$(basename "$APP")"
sign() { # bundle, entitlements
  local exe; exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$1/Info.plist")"
  ldid -S"$2" "$1/$exe"
  echo "signed $(basename "$1") with $(basename "$2")"
}
for ext in "$A"/PlugIns/*.appex; do
  [ -d "$ext" ] || continue
  sign "$ext" "$ROOT/entitlements/$(basename "$ext" .appex).entitlements"
done
sign "$A" "$ROOT/entitlements/ArnavIsland.entitlements"
rm -f "$ROOT/$OUT"
(cd "$WORK" && zip -qry "$ROOT/$OUT" Payload)
ls -la "$ROOT/$OUT"
