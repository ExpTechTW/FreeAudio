#!/usr/bin/env bash
# Puts the signing identity from the repository secrets into a keychain of its own on a GitHub runner, where
# scripts/build-app.sh finds it.
#
# The signature is what an installed FreeAudio trusts: it only installs an update signed by its own team. Use the
# certificate the local builds are signed with, too, because macOS keeps the System Audio Recording permission only
# while the certificate stays the same.
#
# Repository secrets:
#   APPLE_DEV_CERT_BASE64    the certificate and its private key, exported from Keychain Access (My Certificates) as a
#                            .p12, then:  base64 -i FreeAudio.p12 | pbcopy
#   APPLE_DEV_CERT_PASSWORD  the password it was exported with
set -euo pipefail
: "${APPLE_DEV_CERT_BASE64:?set the APPLE_DEV_CERT_BASE64 repository secret}"
: "${APPLE_DEV_CERT_PASSWORD:?set the APPLE_DEV_CERT_PASSWORD repository secret}"
: "${RUNNER_TEMP:?this runs on a GitHub runner}"

keychain="$RUNNER_TEMP/freeaudio-signing.keychain-db"
keychain_password="$(uuidgen)"
p12="$RUNNER_TEMP/freeaudio-signing.p12"

if ! printf '%s' "$APPLE_DEV_CERT_BASE64" | tr -d '[:space:]' | base64 --decode >"$p12" 2>/dev/null; then
  echo "::error::APPLE_DEV_CERT_BASE64 isn't base64. Make it with: base64 -i <the .p12> | pbcopy"
  exit 1
fi
# A .p12 is a DER sequence, which starts with 0x30. Anything else is usually a path pasted instead of the contents.
if [ ! -s "$p12" ] || [ "$(head -c 1 "$p12" | od -An -tx1 | tr -d ' ')" != 30 ]; then
  echo "::error::APPLE_DEV_CERT_BASE64 isn't a .p12. Export the certificate with its key from Keychain Access → My Certificates."
  exit 1
fi

security create-keychain -p "$keychain_password" "$keychain"
# Unlocked for the whole run, so codesign never asks.
security set-keychain-settings -lt 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$p12" -k "$keychain" -P "$APPLE_DEV_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
rm -f "$p12"
# Lets codesign use the key without a prompt nobody is there to answer.
security set-key-partition-list -S apple-tool:,apple: -k "$keychain_password" "$keychain" >/dev/null
# First in the search list, so `security find-identity` in build-app.sh sees it.
existing="$(security list-keychains -d user | tr -d '"' | tr -d ' ')"
# shellcheck disable=SC2086 # one keychain path per word
security list-keychains -d user -s "$keychain" $existing

identities="$(security find-identity -v -p codesigning "$keychain")"
printf '%s\n' "$identities"
if ! printf '%s\n' "$identities" | grep -q '"Apple Development: '; then
  echo "::error::no valid Apple Development identity in APPLE_DEV_CERT_BASE64. Check the .p12 has the private key and hasn't expired, and that APPLE_DEV_CERT_PASSWORD matches it."
  exit 1
fi

certificate="$(security find-certificate -c 'Apple Development' -p "$keychain")"
echo "signing certificate $(printf '%s\n' "$certificate" | openssl x509 -noout -enddate)"
if ! printf '%s\n' "$certificate" | openssl x509 -noout -checkend $((30 * 86400)) >/dev/null; then
  echo "::warning::the signing certificate expires within 30 days. Renew it, then update APPLE_DEV_CERT_BASE64 and APPLE_DEV_CERT_PASSWORD."
fi
