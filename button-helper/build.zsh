#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
app='../build/ScanJet Button.app'
mkdir -p "$app/Contents/MacOS"
xcrun clang -Wall -Wextra -Wno-deprecated-declarations -arch arm64 -mmacosx-version-min=14.0 -c ButtonUSB.c -o ../build/ButtonUSB.o
xcrun clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations -arch arm64 -mmacosx-version-min=14.0 ScanJetButton.m ../build/ButtonUSB.o -framework AppKit -framework ImageCaptureCore -framework PDFKit -framework ImageIO -framework IOKit -o "$app/Contents/MacOS/ScanJet Button"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.cbjarnson.ScanJetButton</string>
<key>CFBundleExecutable</key><string>ScanJet Button</string>
<key>CFBundleName</key><string>ScanJet Button</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
"$app/Contents/MacOS/ScanJet Button" --self-test
print -r -- "Built $app"
