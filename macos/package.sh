#!/bin/sh
# Package both Mac architectures; forward optional --development/--version flags.
set -eu
cd "$(dirname "$0")"
app_name="MagerCam Sender"
asset_name="MagerCam-macOS-universal.zip"
for argument in "$@"; do
    case "$argument" in
        --development)
            app_name="MagerCam Sender Dev"
            asset_name="MagerCam-macOS-universal-dev.zip" ;;
        --help)
            printf 'Usage: ./package.sh [--development] [--version X.Y.Z]\n'
            exit 0 ;;
    esac
done
package_root="$(pwd)/build/package"
MAGERCAM_BUILD_ROOT="$package_root" ./build.sh --universal "$@"
app="$package_root/$app_name.app"
codesign --verify --deep --strict "$app"
lipo "$app/Contents/MacOS/MagerCamSender" -verify_arch arm64 x86_64
mkdir -p build/release
ditto -c -k --sequesterRsrc --keepParent "$app" "build/release/$asset_name"
(
    cd build/release
    shasum -a 256 "$asset_name" > "$asset_name.sha256"
)
printf '\nArchive: %s/build/release/%s\nChecksum: %s/build/release/%s.sha256\n' \
    "$(pwd)" "$asset_name" "$(pwd)" "$asset_name"
