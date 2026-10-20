#!/bin/bash
#
# Puts PathOS back on the iPhone after the seven days a free Apple ID allows.
#
#   ./reinstall.sh
#
# Everything you have saved is kept: places, memories and their photos, events,
# the weekly schedule, trips, mail, scans, expenses. Installing over the top
# keeps the app's own storage — only deleting the app loses it.
#
# The phone needs to be plugged in, unlocked, and trusted. If it isn't, the
# script says so rather than failing halfway.

set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# 1. The phone.
say "Looking for your iPhone…"
devices=$(mktemp -t pathos-devices).json
trap 'rm -f "$devices"' EXIT
xcrun devicectl list devices --json-output "$devices" >/dev/null

read -r device name <<<"$(python3 - "$devices" <<'PY'
import json, sys

# Simulators are in this list too, as "sameMachine". A real iPhone arrives over a
# cable ("wired") or over the network, and its identifier for installing is the
# UDID rather than the one CoreDevice files it under.
found = json.load(open(sys.argv[1]))["result"]["devices"]
phones = [
    device for device in found
    if device.get("hardwareProperties", {}).get("platform") == "iOS"
    and device.get("connectionProperties", {}).get("transportType") != "sameMachine"
]
# A cabled phone first, then whatever is already awake.
phones.sort(key=lambda device: (
    device.get("connectionProperties", {}).get("transportType") != "wired",
    device.get("connectionProperties", {}).get("tunnelState") != "connected",
))
if phones:
    phone = phones[0]
    print(phone["hardwareProperties"]["udid"], phone.get("deviceProperties", {}).get("name", "your iPhone"))
PY
)"

if [ -z "${device:-}" ]; then
    say "No iPhone found."
    cat <<'EOF'
Plug it in with a cable, unlock it, and tap Trust if asked. Then run this again.

If it still isn't found, check:
  • Settings → Privacy & Security → Developer Mode is on (the phone restarts).
  • The cable carries data — some charging cables don't.
EOF
    exit 1
fi
echo "Found ${name}."

# 2. Build it, letting Xcode mint a fresh seven-day certificate.
say "Building…"
xcodegen generate >/dev/null
xcodebuild -project PathOS.xcodeproj -scheme PathOS \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build/DeviceData \
    -allowProvisioningUpdates build \
    -quiet

# 3. Install over the top.
say "Installing onto ${name}…"
xcrun devicectl device install app --device "$device" \
    build/DeviceData/Build/Products/Debug-iphoneos/PathOS.app >/dev/null

say "Done. PathOS is on your phone with everything still in it."

# How long it's good for: the profile Xcode signed it with, which is only a fresh seven days
# when Xcode made a new one — it reuses the one it has until that runs out. Noted for the
# hourly check (Tools/Reinstall), which renews it from there.
profile=build/DeviceData/Build/Products/Debug-iphoneos/PathOS.app/embedded.mobileprovision
ends=$(security cms -D -i "$profile" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null || true)
if [ -n "$ends" ]; then
    seconds=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ends" +%s)
    mkdir -p "$HOME/Library/Application Support/PathOS Reinstall"
    echo "$seconds" > "$HOME/Library/Application Support/PathOS Reinstall/installed-expiry"
    echo "It runs until $(date -r "$seconds" '+%a %-d %b, %-I:%M %p'). If it won't open, go to"
else
    echo "If it won't open, go to"
fi
echo "Settings → General → VPN & Device Management and trust your Apple ID."
