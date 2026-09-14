#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build "Pasito Lab.app/Contents/MacOS"
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
    ../emulator/Core.swift Sources/Protocol.swift Sources/BluetoothLab.swift Sources/PasitoLabApp.swift \
    -framework SwiftUI -framework CoreBluetooth -framework AppKit -o "Pasito Lab.app/Contents/MacOS/PasitoLab"
cat > "Pasito Lab.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.pasito.lab</string>
<key>CFBundleExecutable</key><string>PasitoLab</string>
<key>CFBundleName</key><string>Pasito Lab</string>
<key>CFBundleDisplayName</key><string>Pasito Lab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Сканирование Pasito 3, эмуляция получателя и журналирование Bluetooth-обмена с вашими устройствами.</string>
</dict></plist>
PLIST
codesign --force --sign - "Pasito Lab.app"
plutil -lint "Pasito Lab.app/Contents/Info.plist"
echo "Built: $(pwd)/Pasito Lab.app"
