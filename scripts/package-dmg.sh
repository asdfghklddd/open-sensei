#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
APP="$PWD/build/Open Sensei.app"
[[ -d "$APP" ]] || { print -u2 'Build the app first: ./scripts/build.sh'; exit 1; }
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCH=$(/usr/bin/lipo -archs "$APP/Contents/MacOS/OpenSensei")
[[ "$ARCH" == 'arm64' || "$ARCH" == 'x86_64' ]] || ARCH=universal
mkdir -p dist
STAGE=$(mktemp -d "$PWD/dist/staging.XXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT
ditto "$APP" "$STAGE/Open Sensei.app"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.txt "$STAGE/Read Me - 安装说明.txt"
touch "$STAGE/.metadata_never_index"
OUT="$PWD/dist/Open-Sensei-$VERSION-$ARCH.dmg"
[[ ! -e "$OUT" ]] || { print -u2 "Already exists: $OUT"; exit 1; }
hdiutil create -srcfolder "$STAGE" -volname 'Open Sensei' -fs HFS+ -format UDZO -imagekey zlib-level=9 "$OUT"
hdiutil verify "$OUT"
(cd dist && shasum -a 256 "${OUT:t}" > SHA256SUMS)
print "Created: $OUT"
