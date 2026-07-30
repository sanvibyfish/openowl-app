#!/bin/bash
set -euo pipefail

APP_NAME="openOwl"
DISPLAY_NAME="OpenOwl"
SCHEME="openOwl"
TEAM_ID="${TEAM_ID:-C3NL524YS6}"
ASC_KEY_ID="${ASC_KEY_ID:-7S9R2PS464}"
ASC_ISSUER="${ASC_ISSUER:-d252893a-9fb8-47b9-8254-e62c7d8f76fd}"
ASC_KEY="${ASC_KEY:-$HOME/.private_keys/AuthKey_${ASC_KEY_ID}.p8}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-Developer ID Application: LU CANWEI ($TEAM_ID)}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/$APP_NAME.app"
VERSION=$(grep 'MARKETING_VERSION' "$PROJECT_DIR/project.yml" | head -1 | sed 's/.*: *"\(.*\)"/\1/')
DMG_FINAL="$BUILD_DIR/${DISPLAY_NAME}-${VERSION}.dmg"
DMG_STAGING="$BUILD_DIR/dmg-staging"
MOUNT_POINT=""

run_apple_direct() {
    local apple_no_proxy="timestamp.apple.com,.apple.com,.amazonaws.com"
    if [ -n "${NO_PROXY:-}" ]; then
        apple_no_proxy="${NO_PROXY},${apple_no_proxy}"
    fi
    env NO_PROXY="$apple_no_proxy" no_proxy="$apple_no_proxy" "$@"
}

detach_mount() {
    local mount_point="$1"
    local attempt
    for attempt in 1 2 3 4 5; do
        if hdiutil detach "$mount_point" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    hdiutil detach -force "$mount_point" >/dev/null
}

detach_existing_dmg() {
    local mount_point
    while IFS= read -r mount_point; do
        if [ -n "$mount_point" ]; then
            echo ">>> Detach existing DMG at $mount_point..."
            detach_mount "$mount_point"
        fi
    done < <(
        hdiutil info | awk -v image="$DMG_FINAL" '
            $0 == "image-path      : " image { found = 1; next }
            found && index($0, "/Volumes/") {
                sub(/^.*\t/, "")
                print
                found = 0
            }
            /^=+$/ { found = 0 }
        '
    )
}

cleanup() {
    if [ -n "$MOUNT_POINT" ]; then
        detach_mount "$MOUNT_POINT" >/dev/null 2>&1 || true
    fi
    rm -rf "$DMG_STAGING"
}

assert_no_disallowed_xattrs() {
    local target="$1"
    local disallowed
    disallowed=$(xattr -lr "$target" 2>/dev/null \
        | grep -E 'com\.apple\.(FinderInfo|ResourceFork)' \
        | head -20 \
        || true)
    if [ -n "$disallowed" ]; then
        echo "ERROR: Disallowed extended attributes found in $target"
        echo "$disallowed"
        exit 1
    fi
}

verify_dmg_app() {
    local attach_output
    local mounted_app
    attach_output=$(hdiutil attach -readonly -nobrowse "$DMG_FINAL")
    MOUNT_POINT=$(echo "$attach_output" | sed -n 's|^.*\(/Volumes/.*\)$|\1|p' | tail -1)
    if [ -z "$MOUNT_POINT" ]; then
        echo "ERROR: Unable to determine DMG mount point"
        exit 1
    fi

    mounted_app="$MOUNT_POINT/$APP_NAME.app"
    codesign --verify --deep --strict --verbose=2 "$mounted_app"
    assert_no_disallowed_xattrs "$mounted_app"

    detach_mount "$MOUNT_POINT"
    MOUNT_POINT=""
}

trap cleanup EXIT

echo "=== Building $DISPLAY_NAME v$VERSION ==="

detach_existing_dmg
mkdir -p "$BUILD_DIR"
find "$BUILD_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cd "$PROJECT_DIR"

if [ -z "$NOTARY_PROFILE" ] && [ ! -f "$ASC_KEY" ]; then
    echo "ERROR: App Store Connect API key not found: $ASC_KEY"
    echo "Set ASC_KEY=/path/to/AuthKey_${ASC_KEY_ID}.p8 or NOTARY_PROFILE=<keychain-profile>."
    exit 1
fi

echo ">>> xcodegen..."
xcodegen generate

echo ">>> Archive..."
xcodebuild archive \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    | tail -5

echo ">>> Export (Developer ID + automatic notarization)..."
mkdir -p "$EXPORT_PATH"
cat > "$BUILD_DIR/export-options.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

run_apple_direct xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$BUILD_DIR/export-options.plist" \
    -exportPath "$EXPORT_PATH" \
    | tail -10

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App not found"; ls -la "$EXPORT_PATH/"; exit 1
fi

echo ">>> Verify signature..."
codesign --verify --deep --strict "$APP_PATH"
codesign -dvv "$APP_PATH" 2>&1 | grep "Authority"

echo ">>> Create DMG..."
rm -rf "$DMG_STAGING"
rm -f "$DMG_FINAL"
mkdir -p "$DMG_STAGING"
ditto --norsrc --noextattr --noqtn --noacl "$APP_PATH" "$DMG_STAGING/$APP_NAME.app"
assert_no_disallowed_xattrs "$DMG_STAGING/$APP_NAME.app"
codesign --verify --deep --strict "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create \
    -ov \
    -format UDZO \
    -fs "HFS+" \
    -volname "$DISPLAY_NAME" \
    -srcfolder "$DMG_STAGING" \
    -imagekey zlib-level=9 \
    "$DMG_FINAL"
rm -rf "$DMG_STAGING"

echo ">>> Verify packaged app..."
verify_dmg_app

echo ">>> Sign DMG..."
run_apple_direct codesign --sign "$DEVELOPER_ID_APPLICATION" "$DMG_FINAL"
codesign --verify --verbose=2 "$DMG_FINAL"

echo ">>> Notarize..."
if [ -n "$NOTARY_PROFILE" ]; then
    run_apple_direct xcrun notarytool submit "$DMG_FINAL" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
else
    run_apple_direct xcrun notarytool submit "$DMG_FINAL" \
        --key "$ASC_KEY" \
        --key-id "$ASC_KEY_ID" \
        --issuer "$ASC_ISSUER" \
        --wait
fi

echo ">>> Staple..."
xcrun stapler staple "$DMG_FINAL"
xcrun stapler validate "$DMG_FINAL"

echo ""
echo "=== Done: $DMG_FINAL ==="
ls -lh "$DMG_FINAL"
echo "Gatekeeper:"
spctl --assess --type open --context context:primary-signature --verbose "$DMG_FINAL" 2>&1
