#!/usr/bin/env bash
# Build "KVM Switch.app" (Apple Silicon) and zip it. Needs Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/KVM Switch.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -target arm64-apple-macos13 mac/main.swift \
  -framework AppKit -framework IOKit -framework Carbon -framework ServiceManagement \
  -o "$APP/Contents/MacOS/KVMSwitch"
cp mac/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp mac/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate: swift mac/icon/make-icon.swift mac/AppIcon.icns

codesign --force --sign - "$APP"   # ad-hoc signature (required on Apple Silicon)
(cd build && ditto -c -k --keepParent "KVM Switch.app" KVM-Switch.zip)
echo "built build/KVM-Switch.zip"
