#!/bin/zsh
# Builds Pier.app into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Pier.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Pier "$APP/Contents/MacOS/Pier"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Pier || true
    rm -rf /Applications/Pier.app
    cp -R "$APP" /Applications/
    open /Applications/Pier.app
    echo "Installed and launched /Applications/Pier.app"
fi
