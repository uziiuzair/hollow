#!/bin/bash
# Usage: DEVELOPER_ID_APPLICATION=... TEAM_ID=... NOTARY_PROFILE=... [VERSION=x.y] scripts/release.sh
# Builds, signs with Developer ID, notarizes, staples and zips Hollow.
# DRY_RUN=1 prints the signing and notarization commands (steps 4 to 8) instead of running them.
set -euo pipefail

cd "$(dirname "$0")/.."

DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
export VERSION="${VERSION:-0.1}"
DRY_RUN="${DRY_RUN:-}"

missing=()
[ -n "$DEVELOPER_ID_APPLICATION" ] || missing+=(DEVELOPER_ID_APPLICATION)
[ -n "$TEAM_ID" ] || missing+=(TEAM_ID)
[ -n "$NOTARY_PROFILE" ] || missing+=(NOTARY_PROFILE)
if [ "${#missing[@]}" -gt 0 ]; then
    echo "release.sh: missing ${missing[*]}" >&2
    echo "See docs/release.md for what each one is." >&2
    exit 64
fi

case "$DEVELOPER_ID_APPLICATION" in
    *"($TEAM_ID)") ;;
    *) echo "release.sh: the signing identity is not for team $TEAM_ID" >&2; exit 64 ;;
esac

APP=".build/Hollow.app"
ZIP=".build/Hollow-$VERSION.zip"
ENTITLEMENTS="scripts/Hollow.entitlements"

# run: execute a command, or print it with "+ " under DRY_RUN=1.
run() {
    if [ -n "$DRY_RUN" ]; then
        echo "+ $*"
    else
        "$@"
    fi
}

scripts/make-app.sh release

run codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$DEVELOPER_ID_APPLICATION" "$APP"
run codesign --verify --strict --verbose=2 "$APP"

run ditto -c -k --keepParent "$APP" "$ZIP"

# The profile already names the team; --team-id is kept for clarity (see docs/release.md if notarytool rejects the pair).
if [ -n "$DRY_RUN" ]; then
    echo "+ xcrun notarytool submit $ZIP --keychain-profile $NOTARY_PROFILE --team-id $TEAM_ID --wait --timeout 30m --output-format json"
else
    log="$(mktemp)"
    trap 'rm -f "$log"' EXIT
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --team-id "$TEAM_ID" \
        --wait --timeout 30m --output-format json > "$log"
    cat "$log"
    status="$(plutil -extract status raw -o - "$log" 2>/dev/null || true)"
    if [ "$status" != "Accepted" ]; then
        id="$(plutil -extract id raw -o - "$log" 2>/dev/null || true)"
        echo "release.sh: notarization was not Accepted (status: ${status:-unknown})" >&2
        [ -z "$id" ] || echo "See why: xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
    fi
fi

run xcrun stapler staple "$APP"
run xcrun stapler validate "$APP"
run spctl --assess --type execute -vv "$APP"

run rm -f "$ZIP"
run ditto -c -k --keepParent "$APP" "$ZIP"
echo "Release: $ZIP"
