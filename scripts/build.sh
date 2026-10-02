#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build --disable-sandbox -c release
APP="$PWD/build/Open Sensei.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FanHelper "$APP/Contents/MacOS/FanHelper.next"
mv -f "$APP/Contents/MacOS/FanHelper.next" "$APP/Contents/MacOS/FanHelper"
codesign --force --sign - "$APP/Contents/MacOS/FanHelper"
cp .build/release/OpenSensei "$APP/Contents/MacOS/OpenSensei.next"
mv -f "$APP/Contents/MacOS/OpenSensei.next" "$APP/Contents/MacOS/OpenSensei"
swift -module-cache-path "$PWD/.build/clang-cache" scripts/icon.swift "$PWD/.build/AppIcon.iconset"
cp "$PWD/.build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OpenSensei</string>
<key>CFBundleIdentifier</key><string>local.opensensei.app</string>
<key>CFBundleName</key><string>Open Sensei</string>
<key>CFBundleDisplayName</key><string>Open Sensei</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.2</string>
<key>CFBundleVersion</key><string>14</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
print "已生成：$APP"
