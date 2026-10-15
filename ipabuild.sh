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

# Ad-hoc sign Probe65371.appex so Sideloadly sees CS_EXECSEG_MAIN_BINARY in the
# existing signature when it re-signs with the developer certificate. Without this,
# Sideloadly creates a fresh signature that omits CS_EXECSEG_MAIN_BINARY for
# extension binaries, causing AMFI to kill the extension on launch (iOS 26).
PROBE_APPEX="$TARGET_APP/PlugIns/Probe65371.appex"
if [ -d "$PROBE_APPEX" ]; then
    codesign --sign - --force "$PROBE_APPEX"
    echo "Ad-hoc signed Probe65371.appex (CS_EXECSEG_MAIN_BINARY preserved for Sideloadly)"
fi

mkdir Payload
cp -r "${APPLICATION_NAME}.app" "Payload/${APPLICATION_NAME}.app"
strip "Payload/${APPLICATION_NAME}.app/${APPLICATION_NAME}"
# quiet zip for CI logs; name with underscore for download URLs
zip -qr "Pocket_Poster.ipa" Payload
# keep legacy name too
cp "Pocket_Poster.ipa" "${APPLICATION_NAME}.ipa"
rm -rf "${APPLICATION_NAME}.app"
rm -rf Payload
echo "Built: $WORKING_LOCATION/build/Pocket_Poster.ipa"
echo "Built: $WORKING_LOCATION/build/${APPLICATION_NAME}.ipa"

