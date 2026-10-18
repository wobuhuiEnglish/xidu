#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD="$ROOT/build"
APP="$BUILD/隙读.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
clang -fobjc-arc -arch arm64 -arch x86_64 "$ROOT/Sources/main.m" -o "$APP/Contents/MacOS/Xidu" -framework Cocoa -framework Carbon -framework ServiceManagement -framework UniformTypeIdentifiers -O2
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
echo "$APP"
