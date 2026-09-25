#!/bin/zsh
# Builds, bundles and signs build/FreeAudio.app.
#
#   scripts/build-app.sh              release build, signed with your Developer ID or Apple Development certificate
#   CONFIG=debug scripts/build-app.sh
#   SIGN_IDENTITY=- scripts/build-app.sh   ad-hoc signature (macOS asks for audio permission again after every build,
#                                          and the app can't check updates against its developer)
#   ARCHIVE=1 scripts/build-app.sh    also zip it as build/FreeAudio-<label>.zip, the file a GitHub release carries
#   NOTARIZE=1 scripts/build-app.sh   also have Apple notarize it, so a download opens without Gatekeeper's warning.
#                                     Needs a Developer ID signature, APPLE_ID and APPLE_APP_SPECIFIC_PASSWORD (made at
#                                     account.apple.com → Sign-In and Security → App-Specific Passwords); the team comes
#                                     from the signature unless APPLE_TEAM_ID says otherwise.
#
# The version comes from scripts/version.sh; FREEAUDIO_LABEL/_TRAIN/_CODE/_DATE/_PRERELEASE override it (CI passes the
# values it has checked). Without git history the build is `dev`, build 0.
set -euo pipefail
cd "${0:A:h}/.."

CONFIG=${CONFIG:-release}
BUNDLE_ID=${BUNDLE_ID:-io.github.yuyu1015.FreeAudio}
# The GitHub repository (owner/name) whose releases the app updates from.
UPDATE_REPOSITORY=${UPDATE_REPOSITORY:-ExpTechTW/FreeAudio}
# Apple silicon and Intel, as macOS 26 still runs on both.
ARCHS=(${=ARCHS:-arm64 x86_64})
APP=build/FreeAudio.app

if [[ -z ${FREEAUDIO_CODE:-} ]] && git rev-parse -q --verify HEAD >/dev/null 2>&1; then
    eval "$(scripts/version.sh)"
fi
LABEL=${FREEAUDIO_LABEL:-dev}
TRAIN=${FREEAUDIO_TRAIN:-0.0}
CODE=${FREEAUDIO_CODE:-0}
DATE=${FREEAUDIO_DATE:-}
PRERELEASE=${FREEAUDIO_PRERELEASE:-true}
[[ $PRERELEASE == true ]] && PRERELEASE_TAG="<true/>" || PRERELEASE_TAG="<false/>"

ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN=$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)

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
    <key>CFBundleShortVersionString</key><string>$TRAIN</string>
    <key>CFBundleVersion</key><string>$CODE</string>
    <key>FreeAudioLabel</key><string>$LABEL</string>
    <key>FreeAudioDate</key><string>$DATE</string>
    <key>FreeAudioPrerelease</key>$PRERELEASE_TAG
    <key>FreeAudioRepository</key><string>$UPDATE_REPOSITORY</string>
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
plutil -lint -s "$APP/Contents/Info.plist"

# A stable certificate keeps the System Audio Recording permission across rebuilds, and lets the app check that an
# update comes from the same developer. Developer ID first: it's the one releases are signed with.
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null)
IDENTITY=${SIGN_IDENTITY:-$(print -r -- "$IDENTITIES" | awk -F'"' '/"Developer ID Application: / { print $2; exit }')}
IDENTITY=${IDENTITY:-$(print -r -- "$IDENTITIES" | awk -F'"' '/"Apple Development: / { print $2; exit }')}
if [[ -z "$IDENTITY" ]]; then
    IDENTITY=-
    echo "warning: no Developer ID or Apple Development certificate found; signing ad hoc" >&2
fi
# A Developer ID signature carries Apple's timestamp, so it stays valid after the certificate expires.
[[ $IDENTITY == "Developer ID Application: "* ]] && TIMESTAMP=--timestamp || TIMESTAMP=--timestamp=none
# The hardened runtime, which notarization requires, on every build, so a local build runs as a release does.
codesign --force --options runtime --sign "$IDENTITY" "$TIMESTAMP" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($LABEL, $TRAIN build $CODE, $CONFIG, ${ARCHS[*]}, signed with: $IDENTITY)"

if [[ -n ${NOTARIZE:-} ]]; then
    if [[ $IDENTITY != "Developer ID Application: "* ]]; then
        echo "error: notarizing needs a Developer ID Application signature, not $IDENTITY" >&2
        exit 1
    fi
    : "${APPLE_ID:?set APPLE_ID to notarize}" "${APPLE_APP_SPECIFIC_PASSWORD:?set APPLE_APP_SPECIFIC_PASSWORD to notarize}"
    TEAM=${APPLE_TEAM_ID:-$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')}
    CREDENTIALS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$TEAM")
    SUBMISSION=build/FreeAudio-notarization.zip
    rm -f "$SUBMISSION"
    ditto -c -k --keepParent "$APP" "$SUBMISSION"
    echo "Notarizing $APP (usually a few minutes)"
    # The verdict is read from the result rather than the exit status, so a rejection still prints Apple's reasons.
    RESULT=$(xcrun notarytool submit "$SUBMISSION" "${CREDENTIALS[@]}" --wait --timeout 30m --output-format json || true)
    rm -f "$SUBMISSION"
    field() { print -r -- "$RESULT" | python3 -c "import json, sys; print(json.load(sys.stdin).get('$1', ''))" 2>/dev/null; }
    if [[ $(field status) != Accepted ]]; then
        echo "error: notarization didn't pass: ${RESULT:-no answer from notarytool}" >&2
        [[ -n $(field id) ]] && xcrun notarytool log "$(field id)" "${CREDENTIALS[@]}" >&2 || true
        exit 1
    fi
    # The ticket goes into the app, so it opens without asking Apple, offline too.
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    echo "Notarized $APP ($(field id))"
fi

if [[ -n ${ARCHIVE:-} ]]; then
    ZIP=build/FreeAudio-$LABEL.zip
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    echo "Archived $ZIP"
fi
