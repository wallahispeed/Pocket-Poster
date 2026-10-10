#!/bin/bash

CONFIG="Release"

if [ "$1" == "-d" ]; then
    CONFIG="Debug"
fi

set -e

cd "$(dirname "$0")"

WORKING_LOCATION="$(pwd)"
APPLICATION_NAME="Pocket Poster"

if [ ! -d "build" ]; then
    mkdir build
fi

cd build

xcodebuild -project "$WORKING_LOCATION/$APPLICATION_NAME.xcodeproj" \
    -scheme "$APPLICATION_NAME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$WORKING_LOCATION/build/DerivedDataApp" \
    -destination 'generic/platform=iOS' \
    clean build \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS="" CODE_SIGNING_ALLOWED="NO"

DD_APP_PATH="$WORKING_LOCATION/build/DerivedDataApp/Build/Products/$CONFIG-iphoneos/$APPLICATION_NAME.app"
TARGET_APP="$WORKING_LOCATION/build/$APPLICATION_NAME.app"
cp -r "$DD_APP_PATH" "$TARGET_APP"

codesign --remove "$TARGET_APP"
if [ -e "$TARGET_APP/_CodeSignature" ]; then
    rm -rf "$TARGET_APP/_CodeSignature"
fi
if [ -e "$TARGET_APP/embedded.mobileprovision" ]; then
    rm -rf "$TARGET_APP/embedded.mobileprovision"
fi

# Strip signatures from embedded app extensions (e.g. PhysicsWallpaperExtension)
for APPEX in "$TARGET_APP/PlugIns/"*.appex; do
    [ -d "$APPEX" ] || continue
    codesign --remove "$APPEX" 2>/dev/null || true
    rm -rf "$APPEX/_CodeSignature"
    rm -rf "$APPEX/embedded.mobileprovision"
done

mkdir Payload
cp -r "${APPLICATION_NAME}.app" "Payload/${APPLICATION_NAME}.app"
strip "Payload/${APPLICATION_NAME}.app/${APPLICATION_NAME}"

# Inject private entitlements so TrollStore signs with no-sandbox + platform-application.
# Without this bad_query's sandbox_extension_consume is kernel-refused for all paths.
ENT="$WORKING_LOCATION/entitlements.plist"
if command -v ldid &>/dev/null && [ -f "$ENT" ]; then
    ldid -S"$ENT" "Payload/${APPLICATION_NAME}.app/${APPLICATION_NAME}"
    echo "ldid: entitlements injected from $ENT"
else
    echo "WARNING: ldid not found or entitlements.plist missing — binary has no entitlements"
fi
# quiet zip for CI logs; name with underscore for download URLs
zip -qr "Pocket_Poster.ipa" Payload
# keep legacy name too
cp "Pocket_Poster.ipa" "${APPLICATION_NAME}.ipa"
rm -rf "${APPLICATION_NAME}.app"
rm -rf Payload
echo "Built: $WORKING_LOCATION/build/Pocket_Poster.ipa"
echo "Built: $WORKING_LOCATION/build/${APPLICATION_NAME}.ipa"

