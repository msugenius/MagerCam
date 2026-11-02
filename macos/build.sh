#!/bin/sh
set -eu
cd "$(dirname "$0")"
development=false
universal=false
app_version=
usage() { printf 'Usage: ./build.sh [--development] [--universal] [--version X.Y.Z]\n'; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --development) development=true; shift ;;
        --universal) universal=true; shift ;;
        --version)
            if [ "$#" -lt 2 ]; then usage >&2; exit 2; fi
            app_version="$2"
            if ! printf '%s\n' "$app_version" | grep -Eq '^[0-9]{1,4}\.[0-9]{1,2}\.[0-9]{1,2}$'; then
                printf 'Version must be X.Y.Z (up to 4/2/2 digits for Apple bundle versions).\n' >&2
                exit 2
            fi
            shift 2 ;;
        --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
app_name="MagerCam Sender"
if [ "$development" = true ]; then app_name="MagerCam Sender Dev"; fi
app_root="${MAGERCAM_BUILD_ROOT:-$(pwd)/build}"
case "$app_root" in
    /*) ;;
    *) app_root="$(pwd)/$app_root" ;;
esac
app="$app_root/$app_name.app"
binary_dir="$(pwd)/build/binaries/$app_name"
mkdir -p "$binary_dir" "$app/Contents/MacOS" "$app/Contents/Resources"
compile_arch() {
    target_arch="$1"
    mkdir -p "build/module-cache/$target_arch"
    swiftc -swift-version 5 -O -parse-as-library \
        -target "${target_arch}-apple-macosx13.0" \
        -module-cache-path "$(pwd)/build/module-cache/$target_arch" \
        -framework AppKit -framework SwiftUI -framework AVFoundation \
        -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework Network \
        Sources/MagerCamSender/*.swift \
        -o "$binary_dir/$target_arch"
}
if [ "$universal" = true ]; then
    compile_arch arm64
    compile_arch x86_64
    lipo -create "$binary_dir/arm64" "$binary_dir/x86_64" -output "$app/Contents/MacOS/MagerCamSender"
else
    compile_arch "$(uname -m)"
    cp "$binary_dir/$(uname -m)" "$app/Contents/MacOS/MagerCamSender"
fi
cp Info.plist "$app/Contents/Info.plist"
cp ../LICENSE "$app/Contents/Resources/LICENSE"
if [ -n "$app_version" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $app_version" "$app/Contents/Info.plist"
fi
if [ "$development" = true ]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.magercam.sender.macos.dev' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName MagerCam Sender Dev' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName MagerCam Sender Dev' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :MagerCamTCPPort integer 14848' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :MagerCamDiscoveryPort integer 14849' "$app/Contents/Info.plist"
fi
codesign --force --sign - "$app"
printf '\nBuilt: %s\nOpen: open "%s"\n' "$app" "$app"
