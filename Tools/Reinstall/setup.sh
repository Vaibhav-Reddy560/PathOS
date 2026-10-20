#!/bin/bash
#
# Keeps PathOS on the iPhone from now on: an hourly check that renews it within the last two
# days of its seven (auto-reinstall.sh), and "Reinstall PathOS" in Applications for doing it now.
#
#   ./Tools/Reinstall/setup.sh            set both up, or update them after a change here
#   ./Tools/Reinstall/setup.sh --remove   take both away again
#
# Everything it needs is put on the Mac's own disk — the check, and a copy of the project in
# ~/Developer/PathOS that it brings up to date from GitHub before each build — so the drive the
# project lives on needn't be connected.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$HERE/../.." && pwd)"
LABEL="com.vaibhavreddy.pathos.reinstall"
STATE="$HOME/Library/Application Support/PathOS Reinstall"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$HOME/Applications/Reinstall PathOS.app"
COPY="$HOME/Developer/PathOS"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = "--remove" ]; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$AGENT"
    rm -rf "$APP"
    echo "Removed the hourly check and Reinstall PathOS. Its log is still in $STATE,"
    echo "and the copy it built from in $COPY — delete that too if you won't need it."
    exit 0
fi

mkdir -p "$STATE" "$HOME/Library/LaunchAgents" "$HOME/Applications"
cp "$HERE/auto-reinstall.sh" "$STATE/auto-reinstall.sh"
chmod +x "$STATE/auto-reinstall.sh"

# The copy it builds from: cloned from this one (quick, and no download), then pointed at
# GitHub, where every change is pushed, for keeping up to date.
if [ ! -d "$COPY/.git" ]; then
    mkdir -p "$(dirname "$COPY")"
    git clone --quiet "$PROJECT" "$COPY"
    git -C "$COPY" remote set-url origin "$(git -C "$PROJECT" remote get-url origin)"
fi
git -C "$COPY" pull --ff-only --quiet || echo "Couldn't bring $COPY up to date just now; the check tries again before each build."

# What's on the phone now: the profile in the last build installed. The check counts from it.
BUILT="$PROJECT/build/DeviceData/Build/Products/Debug-iphoneos/PathOS.app/embedded.mobileprovision"
if [ ! -f "$STATE/installed-expiry" ] && [ -f "$BUILT" ]; then
    ends=$(security cms -D -i "$BUILT" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null || true)
    if [ -n "$ends" ]; then
        date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ends" +%s > "$STATE/installed-expiry"
    fi
fi

# Every hour, and whenever you log in. A Mac that was asleep runs it on waking. Through the same
# app you'd double-click, so both run alike, and macOS asks about Reminders on its behalf. A
# fresh "next-run" note in the folder says what this run is — empty for the hourly check; with
# no note, it's you asking for a reinstall.
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>: &gt; "$STATE/next-run" &amp;&amp; /usr/bin/open -g "$APP"</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$STATE/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$STATE/launchd.log</string>
</dict>
</plist>
PLIST
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

# The app: double-clicked, it reinstalls now; opened by the hourly check, it only checks.
# Notifications say how it went.
rm -rf "$APP"
cat > "$STATE/applet.applescript" <<APPLESCRIPT
-- Not "folder": that's a word AppleScript keeps for itself, and setting it stopped the app
-- with an error dialog nobody saw.
set stateFolder to "$STATE/"
set mode to " --now"
try
    -- A note left within the last two minutes says what this run is: empty for the hourly check.
    set mode to " " & (do shell script "f=" & quoted form of (stateFolder & "next-run") & "; test -n \"\$(find \"\$f\" -mmin -2)\" && cat \"\$f\" && rm \"\$f\"")
end try
do shell script "/bin/bash " & quoted form of (stateFolder & "auto-reinstall.sh") & mode & " > /dev/null 2>&1"
APPLESCRIPT
osacompile -o "$APP" "$STATE/applet.applescript"
ICON="$PROJECT/PathOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
if [ -f "$ICON" ]; then
    set_dir="$(mktemp -d)/PathOS.iconset"
    mkdir -p "$set_dir"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ICON" --out "$set_dir/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$ICON" --out "$set_dir/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$set_dir" -o "$APP/Contents/Resources/applet.icns"
fi
# Out of the Dock while it runs: the hourly check would otherwise flash an icon there every hour.
plutil -replace LSUIElement -bool true "$APP/Contents/Info.plist"
# A name of its own, which is what macOS remembers an Allow against.
plutil -replace CFBundleIdentifier -string "com.vaibhavreddy.pathos.reinstaller" "$APP/Contents/Info.plist"
# Sealed again after the changes, so macOS knows it as the same app from run to run.
codesign --force --sign - "$APP" 2>/dev/null

launchctl bootstrap "$DOMAIN" "$AGENT"

echo "Set up."
echo "  • Every hour the Mac checks when PathOS on your phone runs out, and renews it in the last two days."
echo "  • $APP reinstalls it now. Drag it to the Dock to keep it to hand."
echo "  • It builds from $COPY, updated from GitHub first: the Extra Storage drive needn't be connected."
echo "  • What it did is in $STATE/reinstall.log."
