#!/bin/bash
set -euo pipefail

APP_NAME="openOwl"
DISPLAY_NAME="OpenOwl"
SCHEME="openOwl"
TEAM_ID="C3NL524YS6"
ASC_KEY="$HOME/.private_keys/AuthKey_7S9R2PS464.p8"
ASC_KEY_ID="7S9R2PS464"
ASC_ISSUER="d252893a-9fb8-47b9-8254-e62c7d8f76fd"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/$APP_NAME.app"
VERSION=$(grep 'MARKETING_VERSION' "$PROJECT_DIR/project.yml" | head -1 | sed 's/.*: *"\(.*\)"/\1/')
DMG_FINAL="$BUILD_DIR/${DISPLAY_NAME}-${VERSION}.dmg"

echo "=== Building $DISPLAY_NAME v$VERSION ==="

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$PROJECT_DIR"

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

xcodebuild -exportArchive \
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
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_HYBRID="$BUILD_DIR/${DISPLAY_NAME}-${VERSION}.hybrid.dmg"
rm -rf "$DMG_STAGING"
rm -f "$DMG_HYBRID" "$DMG_FINAL"
mkdir -p "$DMG_STAGING"
ditto "$APP_PATH" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil makehybrid -hfs -hfs-volume-name "$DISPLAY_NAME" -o "$DMG_HYBRID" "$DMG_STAGING"
hdiutil convert "$DMG_HYBRID" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL"
rm -f "$DMG_HYBRID"
rm -rf "$DMG_STAGING"

echo ">>> Sign DMG..."
codesign --sign "Developer ID Application: LU CANWEI ($TEAM_ID)" "$DMG_FINAL"

echo ">>> Notarize..."
xcrun notarytool submit "$DMG_FINAL" \
    --key "$ASC_KEY" \
    --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER" \
    --wait

echo ">>> Staple..."
xcrun stapler staple "$DMG_FINAL"

echo ""
echo "=== Done: $DMG_FINAL ==="
ls -lh "$DMG_FINAL"
echo "Gatekeeper:"
spctl --assess --type open --context context:primary-signature --verbose "$DMG_FINAL" 2>&1
