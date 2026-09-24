#!/bin/zsh
# Builds, bundles and signs build/FreeAudio.app.
#
#   scripts/build-app.sh              release build, signed with your Apple Development certificate if you have one
#   CONFIG=debug scripts/build-app.sh
#   SIGN_IDENTITY=- scripts/build-app.sh   ad-hoc signature (macOS asks for audio permission again after every build)
set -euo pipefail
cd "${0:A:h}/.."

CONFIG=${CONFIG:-release}
BUNDLE_ID=${BUNDLE_ID:-io.github.yuyu1015.FreeAudio}
VERSION=${VERSION:-0.1.0}
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
APP=build/FreeAudio.app

swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FreeAudio" "$APP/Contents/MacOS/FreeAudio"
cp -R "$BIN/FreeAudio_FreeAudio.bundle" "$APP/Contents/Resources/"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/"
cp -R Packaging/*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>FreeAudio</string>
    <key>CFBundleDisplayName</key><string>FreeAudio</string>
    <key>CFBundleExecutable</key><string>FreeAudio</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hant</string><string>ja</string></array>
    <key>CFBundleAllowMixedLocalizations</key><true/>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSAudioCaptureUsageDescription</key><string>FreeAudio uses this to change the volume, output device and equalizer of the apps you adjust.</string>
    <key>NSHumanReadableCopyright</key><string>FreeAudio</string>
</dict>
</plist>
PLIST

# A stable certificate keeps the System Audio Recording permission across rebuilds.
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')}
if [[ -z "$IDENTITY" ]]; then
    IDENTITY=-
    echo "warning: no Apple Development certificate found; signing ad hoc" >&2
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION, $CONFIG, signed with: $IDENTITY)"
