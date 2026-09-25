#!/usr/bin/env bash
# Sets the secrets a release signs and notarizes with, on every repository named, from a Developer ID Application
# certificate exported from Keychain Access as a .p12. The certificate is checked first, the way CI will use it, so a
# wrong file or password never reaches a release.
#
#   scripts/set-apple-secrets.sh DeveloperID.p12 ExpTechTW/FreeAudio ExpTechTW/TREM-Lite
#   scripts/set-apple-secrets.sh --dry-run DeveloperID.p12 ExpTechTW/FreeAudio     # checks it, sets nothing
#
# It asks for the .p12's password, then for the Apple ID and app-specific password notarization uses (made at
# account.apple.com → Sign-In and Security → App-Specific Passwords). Leave the Apple ID empty to keep what each
# repository has. The values go to gh on standard input, never on a command line.
#
# The names are the ones tauri-action reads, so TREM-Lite and FreeAudio share them:
#   APPLE_CERTIFICATE  APPLE_CERTIFICATE_PASSWORD  APPLE_TEAM_ID  APPLE_ID  APPLE_APP_SPECIFIC_PASSWORD
set -euo pipefail

dry_run=0
if [ "${1:-}" = --dry-run ]; then
  dry_run=1
  shift
fi
p12="${1:?usage: scripts/set-apple-secrets.sh [--dry-run] <certificate.p12> <owner/repo>...}"
shift
[ $# -gt 0 ] || { echo "name at least one repository, e.g. ExpTechTW/FreeAudio" >&2; exit 2; }
[ -s "$p12" ] || { echo "$p12 isn't a file" >&2; exit 1; }

read -r -s -p "Password of $(basename "$p12"): " password
echo

# A keychain of its own, never added to the search list, so nothing on this Mac changes.
work="$(mktemp -d)"
keychain="$work/check.keychain-db"
trap 'security delete-keychain "$keychain" 2>/dev/null; rm -rf "$work"' EXIT
security create-keychain -p "" "$keychain"
if ! security import "$p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null 2>&1; then
  echo "the .p12 doesn't open with that password" >&2
  exit 1
fi
identity="$(security find-identity -v -p codesigning "$keychain" | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -n 1)"
if [ -z "$identity" ]; then
  echo "no valid Developer ID Application certificate with its private key in $(basename "$p12"):" >&2
  security find-identity -p codesigning "$keychain" | sed 's/^/  /' >&2
  exit 1
fi
certificate="$(security find-certificate -c "$identity" -p "$keychain")"
team="$(printf '%s\n' "$certificate" | openssl x509 -noout -subject -nameopt multiline | awk -F' = ' '/organizationalUnitName/ { print $2; exit }')"
expiry="$(printf '%s\n' "$certificate" | openssl x509 -noout -enddate | cut -d= -f2-)"
issuer="$(printf '%s\n' "$certificate" | openssl x509 -noout -issuer -nameopt multiline | awk -F' = ' '/organizationalUnitName/ { print $2; exit }')"
# Apple's G2 authority issues certificates that last about five years; the previous one, which Xcode can still pick,
# ends every certificate on 2027-02-01.
[ "$issuer" = G2 ] && authority="G2 Sub-CA" || authority="previous Sub-CA"
echo "certificate: $identity"
echo "team:        $team"
echo "expires:     $expiry (issued by Apple's $authority)"
if ! printf '%s\n' "$certificate" | openssl x509 -noout -checkend $((365 * 86400)) >/dev/null; then
  echo "warning: it expires within a year. Make one on developer.apple.com with the G2 Sub-CA, which lasts about five years." >&2
  read -r -p "Set this one anyway? [y/N] " answer
  [ "$answer" = y ] || exit 1
fi

read -r -p "Apple ID for notarization (empty keeps what each repository has): " apple_id
app_password=""
if [ -n "$apple_id" ]; then
  read -r -s -p "App-specific password: " app_password
  echo
fi

names=(APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_TEAM_ID)
values=("$(base64 -i "$p12" | tr -d '\n')" "$password" "$team")
if [ -n "$apple_id" ]; then
  names+=(APPLE_ID APPLE_APP_SPECIFIC_PASSWORD)
  values+=("$apple_id" "$app_password")
fi

for repo in "$@"; do
  gh repo view "$repo" --json name >/dev/null || { echo "can't reach $repo" >&2; exit 1; }
  for i in "${!names[@]}"; do
    if [ "$dry_run" = 1 ]; then
      echo "would set ${names[$i]} on $repo (${#values[$i]} characters)"
    else
      printf '%s' "${values[$i]}" | gh secret set "${names[$i]}" -R "$repo"
      echo "set ${names[$i]} on $repo"
    fi
  done
  # Notarization needs both; a repository that never had them would sign releases but fail to notarize them.
  have="$(gh secret list -R "$repo" --json name --jq '.[].name')"
  for name in APPLE_ID APPLE_APP_SPECIFIC_PASSWORD; do
    printf '%s\n' "$have" | grep -qx "$name" || [ -n "$apple_id" ] ||
      echo "warning: $repo has no $name, so its releases can't be notarized; run this again with an Apple ID" >&2
  done
done
