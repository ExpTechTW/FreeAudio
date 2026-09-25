#!/usr/bin/env bash
# Puts the signing identity from the repository secrets into a keychain of its own on a GitHub runner, and tells
# scripts/build-app.sh which one it is (SIGN_IDENTITY, through $GITHUB_ENV).
#
# The signature is what an installed FreeAudio trusts: it only installs an update signed by its own team. Use the
# team's Developer ID Application certificate, the one for apps given out outside the App Store. macOS then ties the
# System Audio Recording permission to the team, so it stays through every update and certificate renewal. An Apple
# Development certificate works as well, but ties the permission to that one developer's certificate.
#
# Repository secrets, named as tauri-action reads them so TREM-Lite shares them (scripts/set-apple-secrets.sh sets them):
#   APPLE_CERTIFICATE           the certificate and its private key, exported from Keychain Access (My Certificates)
#                               as a .p12, in base64
#   APPLE_CERTIFICATE_PASSWORD  the password it was exported with
set -euo pipefail
: "${APPLE_CERTIFICATE:?set the APPLE_CERTIFICATE repository secret}"
: "${APPLE_CERTIFICATE_PASSWORD:?set the APPLE_CERTIFICATE_PASSWORD repository secret}"
: "${RUNNER_TEMP:?this runs on a GitHub runner}"

keychain="$RUNNER_TEMP/freeaudio-signing.keychain-db"
keychain_password="$(uuidgen)"
p12="$RUNNER_TEMP/freeaudio-signing.p12"

if ! printf '%s' "$APPLE_CERTIFICATE" | tr -d '[:space:]' | base64 --decode >"$p12" 2>/dev/null; then
  echo "::error::APPLE_CERTIFICATE isn't base64. Set it with scripts/set-apple-secrets.sh"
  exit 1
fi
# A .p12 is a DER sequence, which starts with 0x30. Anything else is usually a path pasted instead of the contents.
if [ ! -s "$p12" ] || [ "$(head -c 1 "$p12" | od -An -tx1 | tr -d ' ')" != 30 ]; then
  echo "::error::APPLE_CERTIFICATE isn't a .p12. Export the certificate with its key from Keychain Access → My Certificates."
  exit 1
fi

security create-keychain -p "$keychain_password" "$keychain"
# Unlocked for the whole run, so codesign never asks.
security set-keychain-settings -lt 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$p12" -k "$keychain" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
rm -f "$p12"
# Apple's intermediate certificates for Developer ID, which the chain needs and a runner may not have. Both
# generations: which one issued the certificate depends on when it was made.
for ca in DeveloperIDCA DeveloperIDG2CA; do
  if curl -fsSL --max-time 30 "https://www.apple.com/certificateauthority/$ca.cer" -o "$RUNNER_TEMP/$ca.cer"; then
    security import "$RUNNER_TEMP/$ca.cer" -k "$keychain" >/dev/null 2>&1 || true
  else
    echo "::warning::couldn't download Apple's $ca intermediate certificate"
  fi
done
# Lets codesign use the key without a prompt nobody is there to answer.
security set-key-partition-list -S apple-tool:,apple: -k "$keychain_password" "$keychain" >/dev/null
# First in the search list, so `security find-identity` in build-app.sh sees it.
existing="$(security list-keychains -d user | tr -d '"' | tr -d ' ')"
# shellcheck disable=SC2086 # one keychain path per word
security list-keychains -d user -s "$keychain" $existing

identities="$(security find-identity -v -p codesigning "$keychain")"
printf '%s\n' "$identities"
identity="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -n 1)"
[ -n "$identity" ] || identity="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Apple Development: .*\)"$/\1/p' | head -n 1)"
if [ -z "$identity" ]; then
  echo "::error::no valid Developer ID Application or Apple Development identity in APPLE_CERTIFICATE. Check the .p12 has the private key and hasn't expired, and that APPLE_CERTIFICATE_PASSWORD matches it."
  exit 1
fi
echo "signing with: $identity"
echo "SIGN_IDENTITY=$identity" >> "${GITHUB_ENV:-/dev/null}"

certificate="$(security find-certificate -c "$identity" -p "$keychain")"
echo "signing certificate $(printf '%s\n' "$certificate" | openssl x509 -noout -enddate)"
if ! printf '%s\n' "$certificate" | openssl x509 -noout -checkend $((30 * 86400)) >/dev/null; then
  echo "::warning::the signing certificate expires within 30 days. Make a new one and set it with scripts/set-apple-secrets.sh."
fi
