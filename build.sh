#!/bin/zsh
# Builds LayoutSwitcher.app and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"

APP=build/LayoutSwitcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 Sources/main.swift -o "$APP/Contents/MacOS/LayoutSwitcher" -framework AppKit -framework Carbon
codesign --force -s - --identifier com.vadym.layoutswitcher "$APP"

if [[ "$1" == "--install" ]]; then
    pkill -x LayoutSwitcher 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/LayoutSwitcher.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/LayoutSwitcher.app
    echo "Installed to ~/Applications/LayoutSwitcher.app"
elif [[ "$1" == "--zip" ]]; then
    (cd build && rm -f LayoutSwitcher.zip && ditto -c -k --keepParent LayoutSwitcher.app LayoutSwitcher.zip)
    echo "Built build/LayoutSwitcher.zip"
else
    echo "Built $APP"
fi
