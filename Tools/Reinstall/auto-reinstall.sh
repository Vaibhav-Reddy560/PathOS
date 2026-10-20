#!/bin/bash
#
# Keeps PathOS on the iPhone without anyone running a command.
#
# A free Apple ID signs an app for seven days. Every hour this looks at when the copy on the
# phone runs out, and within the last two days it builds PathOS again with a fresh seven-day
# profile and installs it over Wi-Fi. "Reinstall PathOS" in Applications runs it at once:
#
#   auto-reinstall.sh          the hourly check, from launchd (see setup.sh)
#   auto-reinstall.sh --now    build and install now, whatever the date
#
# It builds from a copy of the project on the Mac's own disk, brought up to date from GitHub
# first, so the drive the project lives on needn't be connected: what's installed is what's
# been pushed. It needs the phone on the same Wi-Fi and unlocked, and Xcode still signed in to
# the Apple ID. When one of those is missing it says which — at most once a day — and tries
# again the next hour.

set -uo pipefail
# launchd starts this with almost no PATH; reinstall.sh needs xcodegen from Homebrew.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

PROJECT="$HOME/Developer/PathOS"
BUILT="$PROJECT/build/DeviceData/Build/Products/Debug-iphoneos/PathOS.app/embedded.mobileprovision"
STATE="$HOME/Library/Application Support/PathOS Reinstall"
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
NAMES=("iOS Team Provisioning Profile: com.vaibhavreddy.pathos"
       "iOS Team Provisioning Profile: com.vaibhavreddy.pathos.widgets")
# When the copy on the phone runs out, in seconds since 1970.
INSTALLED="$STATE/installed-expiry"
# Apple handed back the profile already installed: no point building again before this.
SAME_UNTIL="$STATE/same-profile-until"
RENEW_WITHIN=$((2 * 86400))

mkdir -p "$STATE"
LOG="$STATE/reinstall.log"
SCRATCH="$(mktemp -d -t pathos-reinstall)"
now=$(date +%s)
force=false
[ "${1:-}" = "--now" ] && force=true

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M')" "$*" >> "$LOG"; }

notify() {
    local title=${1//\"/\\\"} message=${2//\"/\\\"}
    osascript -e "display notification \"$message\" with title \"$title\"" >/dev/null 2>&1
}

# A problem is said once a day at most, so an hourly check doesn't nag. Asking for it by hand
# always gets an answer.
tell() {
    local stamp="$STATE/said-$1"
    if ! $force && [ -f "$stamp" ] && [ $((now - $(stat -f %m "$stamp"))) -lt 86400 ]; then return; fi
    touch "$stamp"
    notify "$2" "$3"
}

field() { # profile file, key
    security cms -D -i "$1" > "$SCRATCH/profile.plist" 2>/dev/null || return 1
    plutil -extract "$2" raw "$SCRATCH/profile.plist" 2>/dev/null
}

expiry() { # profile file → seconds since 1970
    local date
    date=$(field "$1" ExpirationDate) || return 1
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$date" +%s 2>/dev/null
}

is_ours() {
    local name
    name=$(field "$1" Name) || return 1
    for ours in "${NAMES[@]}"; do [ "$name" = "$ours" ] && return 0; done
    return 1
}

say_when() { date -r "$1" '+%a %-d %b, %-I:%M %p'; }

finish() { rm -rf "$SCRATCH" "$STATE/lock"; }

# MARK: Is it time?

installed=$(cat "$INSTALLED" 2>/dev/null || echo 0)
if ! $force; then
    [ $((installed - now)) -gt $RENEW_WITHIN ] && { rm -rf "$SCRATCH"; exit 0; }
    if [ -f "$SAME_UNTIL" ] && [ "$now" -lt "$(cat "$SAME_UNTIL")" ]; then rm -rf "$SCRATCH"; exit 0; fi
fi
when=$([ "$installed" -gt 0 ] && say_when "$installed" || echo "soon")

# One at a time: a build takes minutes, and the next hour's check mustn't start another.
if ! mkdir "$STATE/lock" 2>/dev/null; then
    if [ $((now - $(stat -f %m "$STATE/lock"))) -lt 7200 ]; then
        $force && notify "PathOS is already being reinstalled" "It'll say when it's done."
        rm -rf "$SCRATCH"; exit 0
    fi
    # Left behind by a run that didn't finish: taken over.
    touch "$STATE/lock"
fi
trap finish EXIT

if [ ! -d "$PROJECT/.git" ]; then
    log "No copy of the project at $PROJECT."
    tell copy "PathOS runs out $when" "The copy it's built from is missing: run Tools/Reinstall/setup.sh again."
    exit 0
fi

# Up to date with GitHub, so the latest pushed changes go on the phone. Offline, or with the
# copy changed by hand, it builds what it has rather than not at all.
if update=$(git -C "$PROJECT" pull --ff-only --quiet 2>&1); then
    log "Copy at $(git -C "$PROJECT" log -1 --format='%h %s' | cut -c1-80)."
else
    log "Couldn't update the copy, building what it has: $update"
fi

# MARK: Renewing

# Xcode reuses the profile it has until it's expired, so a build days early would put the same
# expiry back on the phone. The cached ones that don't outlast what's installed are held aside,
# and Xcode has to ask Apple for new ones.
held="$STATE/held-profiles"
rm -rf "$held"; mkdir -p "$held"
for file in "$PROFILES"/*.mobileprovision; do
    [ -f "$file" ] && is_ours "$file" || continue
    ends=$(expiry "$file") || continue
    [ "$ends" -le $((installed + 86400)) ] && mv "$file" "$held/"
done

$force && notify "Reinstalling PathOS" "Building and installing over Wi-Fi. This takes a few minutes."
log "Reinstalling (the phone's copy runs out $when)."
output=$(cd "$PROJECT" && ./reinstall.sh 2>&1)
status=$?
printf '%s\n' "$output" >> "$LOG"

# Whatever happened, a profile is never left missing: a held one goes back unless a new one
# for the same app came.
for file in "$held"/*.mobileprovision; do
    [ -f "$file" ] || continue
    name=$(field "$file" Name)
    replaced=false
    for other in "$PROFILES"/*.mobileprovision; do
        [ -f "$other" ] && [ "$(field "$other" Name)" = "$name" ] && replaced=true
    done
    $replaced && rm -f "$file" || mv "$file" "$PROFILES/"
done

if [ $status -ne 0 ]; then
    # Xcode words a lapsed sign-in several ways: rejected, unreadable, or no account at all.
    if grep -q "login details\|Unable to log in\|No Accounts\|Failed to load credentials\|Invalid credentials" <<<"$output"; then
        log "Xcode isn't signed in."
        tell signin "Sign in to Xcode again" "Xcode → Settings → Accounts needs your Apple ID password. PathOS runs out $when."
    elif grep -q "No iPhone found\|could not be established\|Connection reset" <<<"$output"; then
        log "iPhone not reachable."
        tell phone "Couldn't reach your iPhone" "Unlock it on the same Wi-Fi as this Mac. Trying again every hour; PathOS runs out $when."
    else
        log "Failed."
        tell failed "PathOS didn't reinstall" "The reason is in ~/Library/Application Support/PathOS Reinstall/reinstall.log."
    fi
    exit 1
fi

# MARK: Done

renewed=$(expiry "$BUILT" || echo 0)
rm -f "$STATE"/said-*
if [ "$renewed" -le "$installed" ]; then
    # Apple gave the same profile back. It renews once that one has run out.
    echo "$installed" > "$SAME_UNTIL"
    log "Installed, but with the same profile: it still runs out $when."
    $force && notify "PathOS reinstalled" "Apple gave back the same profile, so it still runs out $when. It renews after that."
else
    echo "$renewed" > "$INSTALLED"
    rm -f "$SAME_UNTIL"
    log "Renewed until $(say_when "$renewed")."
    notify "PathOS renewed" "Good until $(say_when "$renewed")."
fi
