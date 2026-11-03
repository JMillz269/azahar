#!/bin/bash -ex

# Builds the native iOS app (SwiftUI frontend + Metal renderer) and packages an unsigned IPA
# that can be signed by a sideloading tool (AltStore, SideStore, Sideloadly...).

BUILD_DIR=${BUILD_DIR:-build/ios}
CONFIG=${CONFIG:-Release}

case "$1" in
configure)
    cmake -S . -B "$BUILD_DIR" -G Xcode \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
        -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
        -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
        -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
        -DENABLE_QT=OFF \
        -DENABLE_SDL2=OFF \
        -DENABLE_WEB_SERVICE=OFF \
        -DENABLE_ROOM=OFF \
        -DENABLE_LTO=OFF \
        -DCITRA_USE_PRECOMPILED_HEADERS=OFF \
        -DENABLE_IOS_APP=ON
    ;;
build)
    cmake --build "$BUILD_DIR" --config "$CONFIG" --target azahar_ios -- \
        -sdk iphoneos -quiet CODE_SIGNING_ALLOWED=NO
    ;;
package)
    APP=$(find "$BUILD_DIR" -name "Azahar.app" -type d -path "*$CONFIG*" | head -n 1)
    if [ -z "$APP" ]; then
        echo "Azahar.app not found"
        exit 1
    fi
    rm -rf artifacts Payload
    mkdir -p artifacts Payload
    cp -R "$APP" Payload/
    zip -qry artifacts/Azahar-unsigned.ipa Payload
    rm -rf Payload
    ls -la artifacts
    ;;
*)
    echo "usage: $0 configure|build|package"
    exit 1
    ;;
esac
