#!/bin/zsh
# Builds build/CampusSwitch.app (ad-hoc signed, this Mac only).
set -euo pipefail
cd "${0:A:h}"
APP=build/CampusSwitch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 5 -parse-as-library -O \
  -target "$(uname -m)-apple-macos13.0" \
  app/CampusSwitch.swift -o "$APP/Contents/MacOS/CampusSwitch"
cp app/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "built $APP"
